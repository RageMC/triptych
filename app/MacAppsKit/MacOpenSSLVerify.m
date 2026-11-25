// SPDX-License-Identifier: GPL-3.0-or-later
// In-process /usr/bin/openssl verification (dgst, smime, cms, x509, verify, version) backed by iOS Security.framework.
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "MacProcessShim.h"

// MARK: - FD I/O helpers

static void WriteFD(int fd, const void *buf, size_t len) {
    if (fd < 0 || !buf || !len) return;
    const uint8_t *p = (const uint8_t *)buf;
    size_t left = len;
    while (left > 0) {
        ssize_t n = write(fd, p, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        p += n;
        left -= (size_t)n;
    }
}

static void WriteStr(int fd, NSString *s) {
    if (!s.length) return;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    WriteFD(fd, d.bytes, d.length);
}

static NSData *ReadFD(int fd) {
    if (fd < 0) return [NSData data];
    NSMutableData *out = [NSMutableData data];
    uint8_t buf[8192];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n > 0) [out appendBytes:buf length:(NSUInteger)n];
        else if (n == 0) break;
        else if (errno != EINTR) break;
    }
    return out;
}

static NSData *ReadInputPath(const char *path, int in_fd) {
    if (!path || strcmp(path, "-") == 0) return ReadFD(in_fd);
    return [NSData dataWithContentsOfFile:@(path)];
}

static BOOL WriteOutputPath(const char *path, int out_fd, NSData *data) {
    if (!data) return YES;
    if (!path || strcmp(path, "-") == 0) {
        WriteFD(out_fd, data.bytes, data.length);
        return YES;
    }
    return [data writeToFile:@(path) atomically:NO];
}

// MARK: - PEM & ASN.1 DER helpers

typedef struct {
    uint8_t tag;
    const uint8_t *tlv;
    size_t tlvLen;
    const uint8_t *val;
    size_t valLen;
    const uint8_t *next;
} ASN1TLV;

static BOOL ASN1Read(const uint8_t *p, const uint8_t *end, ASN1TLV *out) {
    if (!p || p >= end) return NO;
    const uint8_t *start = p;
    uint8_t tag = *p++;
    if ((tag & 0x1F) == 0x1F) {
        while (p < end && (*p & 0x80)) p++;
        if (p >= end) return NO;
        p++;
    }
    if (p >= end) return NO;
    uint8_t lb = *p++;
    size_t len = 0;
    if (lb & 0x80) {
        size_t n = lb & 0x7F;
        if (n == 0 || n > sizeof(size_t) || p + n > end) return NO;
        for (size_t i = 0; i < n; i++) len = (len << 8) | *p++;
    } else {
        len = lb;
    }
    if (len > (size_t)(end - p)) return NO;
    out->tag = tag;
    out->tlv = start;
    out->val = p;
    out->valLen = len;
    out->next = p + len;
    out->tlvLen = (size_t)(out->next - start);
    return YES;
}

static BOOL OIDEquals(const ASN1TLV *t, const uint8_t *oid, size_t oidLen) {
    return t->tag == 0x06 && t->valLen == oidLen && memcmp(t->val, oid, oidLen) == 0;
}

static NSArray<NSData *> *DecodePEMBlocks(NSData *raw, NSArray<NSString *> *labels) {
    NSString *text = [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding];
    if (!text) return @[];
    NSMutableArray<NSData *> *blocks = [NSMutableArray array];
    for (NSString *label in labels) {
        NSString *begin = [NSString stringWithFormat:@"-----BEGIN %@-----", label];
        NSString *end = [NSString stringWithFormat:@"-----END %@-----", label];
        NSRange search = NSMakeRange(0, text.length);
        while (search.location < text.length) {
            NSRange r1 = [text rangeOfString:begin options:0 range:search];
            if (r1.location == NSNotFound) break;
            NSUInteger afterBegin = NSMaxRange(r1);
            NSRange r2 = [text rangeOfString:end options:0 range:NSMakeRange(afterBegin, text.length - afterBegin)];
            if (r2.location == NSNotFound) break;
            NSString *b64 = [text substringWithRange:NSMakeRange(afterBegin, r2.location - afterBegin)];
            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (decoded.length) [blocks addObject:decoded];
            search = NSMakeRange(NSMaxRange(r2), text.length - NSMaxRange(r2));
        }
    }
    return blocks;
}

static NSArray<id> *LoadCertificatesFromData(NSData *raw) {
    if (!raw.length) return @[];
    NSMutableArray *certs = [NSMutableArray array];
    NSArray<NSData *> *pems = DecodePEMBlocks(raw, @[@"CERTIFICATE", @"TRUSTED CERTIFICATE", @"X509 CERTIFICATE"]);
    if (pems.count) {
        for (NSData *der in pems) {
            SecCertificateRef c = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
            if (c) {
                [certs addObject:(__bridge id)c];
                CFRelease(c);
            }
        }
        return certs;
    }
    SecCertificateRef c = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)raw);
    if (c) {
        [certs addObject:(__bridge id)c];
        CFRelease(c);
    }
    return certs;
}

static SecKeyRef CreatePublicKeyFromSPKI(NSData *spki, BOOL *isECOut) CF_RETURNS_RETAINED {
    static const uint8_t kOID_RSA[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01};
    static const uint8_t kOID_EC[]  = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01};
    const uint8_t *b = spki.bytes, *e = b + spki.length;
    ASN1TLV seq, alg, oid, bits;
    if (ASN1Read(b, e, &seq) && seq.tag == 0x30 &&
        ASN1Read(seq.val, seq.val + seq.valLen, &alg) && alg.tag == 0x30 &&
        ASN1Read(alg.val, alg.val + alg.valLen, &oid) &&
        ASN1Read(alg.next, seq.val + seq.valLen, &bits) && bits.tag == 0x03 && bits.valLen > 1) {
        NSData *inner = [NSData dataWithBytes:bits.val + 1 length:bits.valLen - 1];
        if (OIDEquals(&oid, kOID_EC, sizeof kOID_EC)) {
            if (isECOut) *isECOut = YES;
            NSDictionary *attrs = @{
                (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
                (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
            };
            return SecKeyCreateWithData((__bridge CFDataRef)inner, (__bridge CFDictionaryRef)attrs, NULL);
        }
        if (OIDEquals(&oid, kOID_RSA, sizeof kOID_RSA)) {
            if (isECOut) *isECOut = NO;
            NSDictionary *attrs = @{
                (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
                (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
            };
            SecKeyRef k = SecKeyCreateWithData((__bridge CFDataRef)inner, (__bridge CFDictionaryRef)attrs, NULL);
            if (k) return k;
        }
    }
    NSDictionary *rsaAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
    };
    SecKeyRef k = SecKeyCreateWithData((__bridge CFDataRef)spki, (__bridge CFDictionaryRef)rsaAttrs, NULL);
    if (k) {
        if (isECOut) *isECOut = NO;
        return k;
    }
    return NULL;
}

static SecKeyRef LoadPublicKeyFromFile(const char *path, BOOL *isECOut) CF_RETURNS_RETAINED {
    NSData *raw = [NSData dataWithContentsOfFile:@(path)];
    if (!raw.length) return NULL;
    NSArray<NSData *> *pubBlocks = DecodePEMBlocks(raw, @[@"PUBLIC KEY"]);
    if (pubBlocks.count) return CreatePublicKeyFromSPKI(pubBlocks.firstObject, isECOut);

    NSArray<NSData *> *rsaBlocks = DecodePEMBlocks(raw, @[@"RSA PUBLIC KEY"]);
    if (rsaBlocks.count) {
        if (isECOut) *isECOut = NO;
        NSDictionary *attrs = @{
            (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
            (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
        };
        return SecKeyCreateWithData((__bridge CFDataRef)rsaBlocks.firstObject, (__bridge CFDictionaryRef)attrs, NULL);
    }

    NSArray *certs = LoadCertificatesFromData(raw);
    if (certs.count) {
        SecKeyRef k = SecCertificateCopyKey((__bridge SecCertificateRef)certs.firstObject);
        if (k && isECOut) {
            NSDictionary *attrs = CFBridgingRelease(SecKeyCopyAttributes(k));
            *isECOut = [attrs[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom];
        }
        return k;
    }

    SecKeyRef k = CreatePublicKeyFromSPKI(raw, isECOut);
    if (k) return k;
    NSDictionary *ecAttrs = @{
        (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeECSECPrimeRandom,
        (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPublic,
    };
    k = SecKeyCreateWithData((__bridge CFDataRef)raw, (__bridge CFDictionaryRef)ecAttrs, NULL);
    if (k && isECOut) *isECOut = YES;
    return k;
}

typedef enum {
    DigestSHA1,
    DigestSHA256,
    DigestSHA384,
    DigestSHA512,
} MacDigestKind;

static SecKeyAlgorithm SignatureAlgorithmFor(MacDigestKind digest, BOOL isEC) {
    if (isEC) {
        switch (digest) {
        case DigestSHA1:   return kSecKeyAlgorithmECDSASignatureMessageX962SHA1;
        case DigestSHA256: return kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
        case DigestSHA384: return kSecKeyAlgorithmECDSASignatureMessageX962SHA384;
        case DigestSHA512: return kSecKeyAlgorithmECDSASignatureMessageX962SHA512;
        }
    }
    switch (digest) {
    case DigestSHA1:   return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1;
    case DigestSHA256: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256;
    case DigestSHA384: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384;
    case DigestSHA512: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512;
    }
}

static NSData *ComputeDigest(MacDigestKind kind, NSData *data) {
    uint8_t out[CC_SHA512_DIGEST_LENGTH];
    CC_LONG len = (CC_LONG)data.length;
    switch (kind) {
    case DigestSHA1:   CC_SHA1(data.bytes, len, out);   return [NSData dataWithBytes:out length:CC_SHA1_DIGEST_LENGTH];
    case DigestSHA256: CC_SHA256(data.bytes, len, out); return [NSData dataWithBytes:out length:CC_SHA256_DIGEST_LENGTH];
    case DigestSHA384: CC_SHA384(data.bytes, len, out); return [NSData dataWithBytes:out length:CC_SHA384_DIGEST_LENGTH];
    case DigestSHA512: CC_SHA512(data.bytes, len, out); return [NSData dataWithBytes:out length:CC_SHA512_DIGEST_LENGTH];
    }
}

// MARK: - `openssl dgst`

static int RunDgst(int argc, const char *const *argv, int startIdx, MacDigestKind defaultDigest, int in_fd, int out_fd, int err_fd) {
    MacDigestKind digest = defaultDigest;
    const char *verifyKey = NULL;
    const char *sigPath = NULL;
    const char *dataPath = NULL;
    const char *outPath = NULL;
    BOOL doVerify = NO;

    for (int i = startIdx; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-sha1")) digest = DigestSHA1;
        else if (!strcmp(a, "-sha256")) digest = DigestSHA256;
        else if (!strcmp(a, "-sha384")) digest = DigestSHA384;
        else if (!strcmp(a, "-sha512")) digest = DigestSHA512;
        else if (!strcmp(a, "-verify") && i + 1 < argc) { doVerify = YES; verifyKey = argv[++i]; }
        else if (!strcmp(a, "-prverify") && i + 1 < argc) { doVerify = YES; verifyKey = argv[++i]; }
        else if (!strcmp(a, "-signature") && i + 1 < argc) sigPath = argv[++i];
        else if (!strcmp(a, "-out") && i + 1 < argc) outPath = argv[++i];
        else if (!strcmp(a, "-keyform") && i + 1 < argc) i++;
        else if (!strcmp(a, "-engine") && i + 1 < argc) i++;
        else if (!strcmp(a, "-pubin") || !strcmp(a, "-binary") || !strcmp(a, "-hex") || !strcmp(a, "-r")) {}
        else if (a[0] == '-' && a[1] != '\0') {
            WriteStr(err_fd, [NSString stringWithFormat:@"openssl dgst: unsupported option %s\n", a]);
            return 2;
        } else if (!dataPath) {
            dataPath = a;
        } else {
            WriteStr(err_fd, @"openssl dgst: expected one input file\n");
            return 2;
        }
    }

    if (!doVerify || !verifyKey || !sigPath) {
        WriteStr(err_fd, @"openssl dgst: -verify and -signature are required\n");
        return 2;
    }

    BOOL isEC = NO;
    SecKeyRef key = LoadPublicKeyFromFile(verifyKey, &isEC);
    if (!key) {
        WriteStr(err_fd, [NSString stringWithFormat:@"unable to load key file %s\n", verifyKey]);
        return 1;
    }
    NSData *sig = [NSData dataWithContentsOfFile:@(sigPath)];
    NSData *msg = ReadInputPath(dataPath, in_fd);
    if (!sig || !msg) {
        CFRelease(key);
        WriteStr(err_fd, @"Error reading signature or input data\n");
        return 1;
    }

    CFErrorRef err = NULL;
    Boolean ok = SecKeyVerifySignature(key, SignatureAlgorithmFor(digest, isEC),
                                       (__bridge CFDataRef)msg, (__bridge CFDataRef)sig, &err);
    CFRelease(key);
    if (err) CFRelease(err);

#if DEBUG
    fprintf(stderr, "MacAppsKit: openssl dgst signature %s\n", ok ? "verified" : "rejected");
#endif
    NSString *res = ok ? @"Verified OK\n" : @"Verification failure\n";
    WriteOutputPath(outPath, out_fd, [res dataUsingEncoding:NSUTF8StringEncoding]);
    return ok ? 0 : 1;
}

// MARK: - `openssl smime -verify` / `openssl cms -verify`

static BOOL ParseDigestOID(const ASN1TLV *algSeq, MacDigestKind *out) {
    static const uint8_t kSHA1[]   = {0x2B, 0x0E, 0x03, 0x02, 0x1A};
    static const uint8_t kSHA256[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01};
    static const uint8_t kSHA384[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02};
    static const uint8_t kSHA512[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03};
    static const uint8_t kRSASHA1[]   = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x05};
    static const uint8_t kRSASHA256[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B};
    static const uint8_t kRSASHA384[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C};
    static const uint8_t kRSASHA512[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D};
    static const uint8_t kECSHA1[]   = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x01};
    static const uint8_t kECSHA256[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02};
    static const uint8_t kECSHA384[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03};
    static const uint8_t kECSHA512[] = {0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04};
    ASN1TLV oid;
    if (!ASN1Read(algSeq->val, algSeq->val + algSeq->valLen, &oid) || oid.tag != 0x06) return NO;
    if (OIDEquals(&oid, kSHA1, sizeof kSHA1) || OIDEquals(&oid, kRSASHA1, sizeof kRSASHA1) || OIDEquals(&oid, kECSHA1, sizeof kECSHA1)) {
        *out = DigestSHA1; return YES;
    }
    if (OIDEquals(&oid, kSHA256, sizeof kSHA256) || OIDEquals(&oid, kRSASHA256, sizeof kRSASHA256) || OIDEquals(&oid, kECSHA256, sizeof kECSHA256)) {
        *out = DigestSHA256; return YES;
    }
    if (OIDEquals(&oid, kSHA384, sizeof kSHA384) || OIDEquals(&oid, kRSASHA384, sizeof kRSASHA384) || OIDEquals(&oid, kECSHA384, sizeof kECSHA384)) {
        *out = DigestSHA384; return YES;
    }
    if (OIDEquals(&oid, kSHA512, sizeof kSHA512) || OIDEquals(&oid, kRSASHA512, sizeof kRSASHA512) || OIDEquals(&oid, kECSHA512, sizeof kECSHA512)) {
        *out = DigestSHA512; return YES;
    }
    return NO;
}

static BOOL ExtractSMIMEMultipart(NSData *raw, NSData **contentOut, NSData **pkcs7Out) {
    NSString *s = [[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    if (!s) return NO;
    NSRange br = [s rangeOfString:@"boundary=" options:NSCaseInsensitiveSearch];
    if (br.location == NSNotFound) return NO;
    NSUInteger pos = NSMaxRange(br);
    while (pos < s.length && ([s characterAtIndex:pos] == ' ' || [s characterAtIndex:pos] == '"')) pos++;
    NSUInteger end = pos;
    while (end < s.length) {
        unichar c = [s characterAtIndex:end];
        if (c == '"' || c == ';' || c == '\r' || c == '\n' || c == ' ') break;
        end++;
    }
    if (end <= pos) return NO;
    NSString *boundary = [@"--" stringByAppendingString:[s substringWithRange:NSMakeRange(pos, end - pos)]];
    NSData *bData = [boundary dataUsingEncoding:NSISOLatin1StringEncoding];
    NSRange r1 = [raw rangeOfData:bData options:0 range:NSMakeRange(0, raw.length)];
    if (r1.location == NSNotFound) return NO;
    NSUInteger p1 = NSMaxRange(r1);
    // Skip line ending after boundary
    const uint8_t *bytes = raw.bytes;
    if (p1 < raw.length && bytes[p1] == '\r') p1++;
    if (p1 < raw.length && bytes[p1] == '\n') p1++;
    NSRange r2 = [raw rangeOfData:bData options:0 range:NSMakeRange(p1, raw.length - p1)];
    if (r2.location == NSNotFound) return NO;
    NSUInteger p1End = r2.location;
    if (p1End > p1 && bytes[p1End - 1] == '\n') p1End--;
    if (p1End > p1 && bytes[p1End - 1] == '\r') p1End--;
    *contentOut = [raw subdataWithRange:NSMakeRange(p1, p1End - p1)];

    NSUInteger p2 = NSMaxRange(r2);
    NSRange r3 = [raw rangeOfData:bData options:0 range:NSMakeRange(p2, raw.length - p2)];
    NSUInteger p2End = (r3.location != NSNotFound) ? r3.location : raw.length;
    NSData *part2 = [raw subdataWithRange:NSMakeRange(p2, p2End - p2)];
    NSData *crlf2 = [@"\r\n\r\n" dataUsingEncoding:NSISOLatin1StringEncoding];
    NSData *lf2 = [@"\n\n" dataUsingEncoding:NSISOLatin1StringEncoding];
    NSRange hdrEnd = [part2 rangeOfData:crlf2 options:0 range:NSMakeRange(0, part2.length)];
    if (hdrEnd.location == NSNotFound) hdrEnd = [part2 rangeOfData:lf2 options:0 range:NSMakeRange(0, part2.length)];
    if (hdrEnd.location == NSNotFound) return NO;
    NSData *b64Data = [part2 subdataWithRange:NSMakeRange(NSMaxRange(hdrEnd), part2.length - NSMaxRange(hdrEnd))];
    NSString *b64Str = [[NSString alloc] initWithData:b64Data encoding:NSISOLatin1StringEncoding];
    *pkcs7Out = [[NSData alloc] initWithBase64EncodedString:b64Str options:NSDataBase64DecodingIgnoreUnknownCharacters];
    return (*pkcs7Out).length > 0;
}

static BOOL VerifyTrustChain(NSArray *certs, NSArray *anchors, BOOL noVerify) {
    if (noVerify) return YES;
    if (!certs.count) return NO;
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    OSStatus st = SecTrustCreateWithCertificates((__bridge CFArrayRef)certs, policy, &trust);
    if (policy) CFRelease(policy);
    if (st != errSecSuccess || !trust) return NO;
    if (anchors.count) {
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)anchors);
        SecTrustSetAnchorCertificatesOnly(trust, true);
    }
    SecTrustSetNetworkFetchAllowed(trust, false);
    CFErrorRef err = NULL;
    bool ok = SecTrustEvaluateWithError(trust, &err);
    if (err) CFRelease(err);
    CFRelease(trust);
    return ok ? YES : NO;
}

static BOOL VerifySignedDataCMS(NSData *der, NSData *detachedContent, NSArray *extraCerts, NSArray *anchors,
                                BOOL noVerify, NSData **verifiedContentOut) {
    static const uint8_t kSignedDataOID[] = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02};
    static const uint8_t kMsgDigestOID[]  = {0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04};
    const uint8_t *b = der.bytes, *e = b + der.length;
    ASN1TLV ci, oid, wrap, sd, ver, dalgs, eci;
    if (!ASN1Read(b, e, &ci) || ci.tag != 0x30) return NO;
    if (!ASN1Read(ci.val, ci.val + ci.valLen, &oid) || !OIDEquals(&oid, kSignedDataOID, sizeof kSignedDataOID)) return NO;
    if (!ASN1Read(oid.next, ci.val + ci.valLen, &wrap) || wrap.tag != 0xA0) return NO;
    if (!ASN1Read(wrap.val, wrap.val + wrap.valLen, &sd) || sd.tag != 0x30) return NO;

    const uint8_t *sdEnd = sd.val + sd.valLen;
    if (!ASN1Read(sd.val, sdEnd, &ver) || ver.tag != 0x02) return NO;
    if (!ASN1Read(ver.next, sdEnd, &dalgs) || dalgs.tag != 0x31) return NO;
    if (!ASN1Read(dalgs.next, sdEnd, &eci) || eci.tag != 0x30) return NO;

    // encapContentInfo: OID [0] EXPLICIT OCTET STRING OPTIONAL
    NSData *content = detachedContent;
    ASN1TLV eciOid, eciWrap;
    if (ASN1Read(eci.val, eci.val + eci.valLen, &eciOid) && eciOid.next < eci.val + eci.valLen) {
        if (ASN1Read(eciOid.next, eci.val + eci.valLen, &eciWrap) && eciWrap.tag == 0xA0) {
            ASN1TLV oct;
            if (ASN1Read(eciWrap.val, eciWrap.val + eciWrap.valLen, &oct) && oct.tag == 0x04) {
                content = [NSData dataWithBytes:oct.val length:oct.valLen];
            }
        }
    }
    if (!content) return NO;

    NSMutableArray *certs = [NSMutableArray array];
    const uint8_t *cur = eci.next;
    ASN1TLV opt;
    while (cur < sdEnd && ASN1Read(cur, sdEnd, &opt)) {
        if (opt.tag == 0xA0) {
            const uint8_t *cp = opt.val, *ce = opt.val + opt.valLen;
            ASN1TLV c;
            while (cp < ce && ASN1Read(cp, ce, &c)) {
                SecCertificateRef sc = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)[NSData dataWithBytes:c.tlv length:c.tlvLen]);
                if (sc) { [certs addObject:(__bridge id)sc]; CFRelease(sc); }
                cp = c.next;
            }
            cur = opt.next;
        } else if (opt.tag == 0xA1) {
            cur = opt.next; // CRLs
        } else {
            break;
        }
    }
    [certs addObjectsFromArray:extraCerts];
    if (cur >= sdEnd) return NO;

    ASN1TLV sis;
    if (!ASN1Read(cur, sdEnd, &sis) || sis.tag != 0x31) return NO;
    const uint8_t *sp = sis.val, *se = sis.val + sis.valLen;
    int verifiedCount = 0;
    while (sp < se) {
        ASN1TLV si;
        if (!ASN1Read(sp, se, &si) || si.tag != 0x30) return NO;
        sp = si.next;
        const uint8_t *siEnd = si.val + si.valLen;
        ASN1TLV sver, sid, digAlg, nextTlv;
        if (!ASN1Read(si.val, siEnd, &sver) || !ASN1Read(sver.next, siEnd, &sid) || !ASN1Read(sid.next, siEnd, &digAlg)) return NO;
        MacDigestKind digKind = DigestSHA256;
        if (!ParseDigestOID(&digAlg, &digKind)) return NO;

        const uint8_t *signedAttrsRaw = NULL;
        size_t signedAttrsLen = 0;
        const uint8_t *pAfterAttrs = digAlg.next;
        if (!ASN1Read(pAfterAttrs, siEnd, &nextTlv)) return NO;
        if (nextTlv.tag == 0xA0) {
            signedAttrsRaw = nextTlv.tlv;
            signedAttrsLen = nextTlv.tlvLen;
            // Verify messageDigest attribute inside signedAttrs
            BOOL checkedMD = NO;
            const uint8_t *ap = nextTlv.val, *ae = nextTlv.val + nextTlv.valLen;
            ASN1TLV attr;
            while (ap < ae && ASN1Read(ap, ae, &attr)) {
                ASN1TLV aoid, aset, aval;
                if (attr.tag == 0x30 &&
                    ASN1Read(attr.val, attr.val + attr.valLen, &aoid) &&
                    OIDEquals(&aoid, kMsgDigestOID, sizeof kMsgDigestOID) &&
                    ASN1Read(aoid.next, attr.val + attr.valLen, &aset) && aset.tag == 0x31 &&
                    ASN1Read(aset.val, aset.val + aset.valLen, &aval) && aval.tag == 0x04) {
                    NSData *expected = ComputeDigest(digKind, content);
                    if (aval.valLen != expected.length || memcmp(aval.val, expected.bytes, expected.length) != 0) return NO;
                    checkedMD = YES;
                }
                ap = attr.next;
            }
            if (!checkedMD) return NO;
            pAfterAttrs = nextTlv.next;
            if (!ASN1Read(pAfterAttrs, siEnd, &nextTlv)) return NO;
        }
        ASN1TLV sigAlg = nextTlv, sigOct;
        if (sigAlg.tag != 0x30 || !ASN1Read(sigAlg.next, siEnd, &sigOct) || sigOct.tag != 0x04) return NO;
        (void)ParseDigestOID(&sigAlg, &digKind);

        NSData *signedPayload = nil;
        if (signedAttrsRaw) {
            NSMutableData *retagged = [NSMutableData dataWithBytes:signedAttrsRaw length:signedAttrsLen];
            uint8_t setTag = 0x31;
            [retagged replaceBytesInRange:NSMakeRange(0, 1) withBytes:&setTag];
            signedPayload = retagged;
        } else {
            signedPayload = content;
        }
        NSData *sigBytes = [NSData dataWithBytes:sigOct.val length:sigOct.valLen];

        // Try matching certificate in certs
        BOOL sigOK = NO;
        SecCertificateRef matchedCert = NULL;
        for (id cObj in certs) {
            SecCertificateRef sc = (__bridge SecCertificateRef)cObj;
            SecKeyRef key = SecCertificateCopyKey(sc);
            if (!key) continue;
            NSDictionary *attrs = CFBridgingRelease(SecKeyCopyAttributes(key));
            BOOL isEC = [attrs[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom];
            CFErrorRef err = NULL;
            Boolean ok = SecKeyVerifySignature(key, SignatureAlgorithmFor(digKind, isEC),
                                               (__bridge CFDataRef)signedPayload, (__bridge CFDataRef)sigBytes, &err);
            if (err) CFRelease(err);
            CFRelease(key);
            if (ok) {
                sigOK = YES;
                matchedCert = sc;
                break;
            }
        }
        if (!sigOK) return NO;

        // Build chain starting with matchedCert
        NSMutableArray *chain = [NSMutableArray arrayWithObject:(__bridge id)matchedCert];
        for (id cObj in certs) {
            if ((__bridge SecCertificateRef)cObj != matchedCert) [chain addObject:cObj];
        }
        if (!VerifyTrustChain(chain, anchors, noVerify)) return NO;
        verifiedCount++;
    }
    if (verifiedCount == 0) return NO;
    if (verifiedContentOut) *verifiedContentOut = content;
    return YES;
}

static int RunSMIME(int argc, const char *const *argv, int startIdx, int in_fd, int out_fd, int err_fd) {
    BOOL doVerify = NO, noVerify = NO;
    const char *inPath = NULL, *outPath = NULL, *contentPath = NULL, *caFile = NULL, *certFile = NULL;
    NSString *inform = @"SMIME";

    for (int i = startIdx; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-verify")) doVerify = YES;
        else if (!strcmp(a, "-noverify")) noVerify = YES;
        else if (!strcmp(a, "-binary")) {}
        else if (!strcmp(a, "-in") && i + 1 < argc) inPath = argv[++i];
        else if (!strcmp(a, "-out") && i + 1 < argc) outPath = argv[++i];
        else if (!strcmp(a, "-content") && i + 1 < argc) contentPath = argv[++i];
        else if (!strcmp(a, "-inform") && i + 1 < argc) inform = [@(argv[++i]) uppercaseString];
        else if (!strcmp(a, "-CAfile") && i + 1 < argc) caFile = argv[++i];
        else if (!strcmp(a, "-certfile") && i + 1 < argc) certFile = argv[++i];
        else {
            WriteStr(err_fd, @"openssl smime: unsupported option\n");
            return 2;
        }
    }

    if (!doVerify) {
        WriteStr(err_fd, @"openssl smime: only -verify is supported\n");
        return 2;
    }

    NSData *raw = ReadInputPath(inPath, in_fd);
    if (!raw.length) {
        WriteStr(err_fd, @"Verification failure\n");
        return 1;
    }

    NSData *detached = contentPath ? [NSData dataWithContentsOfFile:@(contentPath)] : nil;
    NSData *pkcs7 = nil;
    if ([inform isEqualToString:@"DER"]) {
        pkcs7 = raw;
    } else if ([inform isEqualToString:@"PEM"]) {
        pkcs7 = DecodePEMBlocks(raw, @[@"PKCS7", @"CMS"]).firstObject;
    } else {
        const uint8_t *rb = raw.bytes;
        if (raw.length && rb[0] == 0x30) {
            pkcs7 = raw;
        } else if ((pkcs7 = DecodePEMBlocks(raw, @[@"PKCS7", @"CMS"]).firstObject) == nil) {
            NSData *mimeContent = nil;
            if (ExtractSMIMEMultipart(raw, &mimeContent, &pkcs7)) {
                if (!detached) detached = mimeContent;
            } else {
                // Inline base64 body after MIME headers
                NSData *crlf2 = [@"\r\n\r\n" dataUsingEncoding:NSISOLatin1StringEncoding];
                NSData *lf2 = [@"\n\n" dataUsingEncoding:NSISOLatin1StringEncoding];
                NSRange hdrEnd = [raw rangeOfData:crlf2 options:0 range:NSMakeRange(0, raw.length)];
                if (hdrEnd.location == NSNotFound) hdrEnd = [raw rangeOfData:lf2 options:0 range:NSMakeRange(0, raw.length)];
                if (hdrEnd.location != NSNotFound) {
                    NSData *b64 = [raw subdataWithRange:NSMakeRange(NSMaxRange(hdrEnd), raw.length - NSMaxRange(hdrEnd))];
                    NSString *b64s = [[NSString alloc] initWithData:b64 encoding:NSISOLatin1StringEncoding];
                    pkcs7 = [[NSData alloc] initWithBase64EncodedString:b64s options:NSDataBase64DecodingIgnoreUnknownCharacters];
                }
            }
        }
    }

    if (!pkcs7.length) {
        WriteStr(err_fd, @"Verification failure\n");
        return 1;
    }

    NSArray *anchors = caFile ? LoadCertificatesFromData([NSData dataWithContentsOfFile:@(caFile)]) : @[];
    NSArray *extra = certFile ? LoadCertificatesFromData([NSData dataWithContentsOfFile:@(certFile)]) : @[];
    if ((caFile && !anchors.count) || (certFile && !extra.count)) {
        WriteStr(err_fd, @"unable to load verification certificates\n");
        return 1;
    }
    NSData *verified = nil;
    BOOL ok = VerifySignedDataCMS(pkcs7, detached, extra, anchors, noVerify, &verified);
    if (!ok) {
        WriteStr(err_fd, @"Verification failure\n");
        return 1;
    }
    if (verified.length) WriteOutputPath(outPath, out_fd, verified);
    WriteStr(err_fd, @"Verification successful\n");
    return 0;
}

// MARK: - `openssl x509 -verify` / `openssl verify`

static int RunX509OrVerify(BOOL isVerifyCmd, int argc, const char *const *argv, int startIdx, int in_fd, int out_fd, int err_fd) {
    const char *inPath = NULL, *outPath = NULL, *caFile = NULL;
    BOOL doVerify = isVerifyCmd, wantPubkey = NO, noout = NO;

    for (int i = startIdx; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "-verify")) doVerify = YES;
        else if (!strcmp(a, "-pubkey")) wantPubkey = YES;
        else if (!strcmp(a, "-noout")) noout = YES;
        else if (!strcmp(a, "-in") && i + 1 < argc) inPath = argv[++i];
        else if (!strcmp(a, "-out") && i + 1 < argc) outPath = argv[++i];
        else if ((!strcmp(a, "-CAfile") || !strcmp(a, "-CA")) && i + 1 < argc) caFile = argv[++i];
        else if (isVerifyCmd && a[0] != '-' && !inPath) inPath = a;
        else {
            WriteStr(err_fd, @"openssl x509/verify: unsupported option\n");
            return 2;
        }
    }

    NSData *raw = ReadInputPath(inPath, in_fd);
    NSArray *certs = LoadCertificatesFromData(raw);
    if (!certs.count) {
        WriteStr(err_fd, @"unable to load certificate\n");
        return 1;
    }

    if (wantPubkey) {
        SecCertificateRef leaf = (__bridge SecCertificateRef)certs.firstObject;
        SecKeyRef key = SecCertificateCopyKey(leaf);
        if (!key) return 1;
        CFErrorRef err = NULL;
        NSData *ext = CFBridgingRelease(SecKeyCopyExternalRepresentation(key, &err));
        CFRelease(key);
        if (err) { CFRelease(err); return 1; }
        NSString *b64 = [ext base64EncodedStringWithOptions:NSDataBase64Encoding64CharacterLineLength | NSDataBase64EncodingEndLineWithLineFeed];
        NSString *pem = [NSString stringWithFormat:@"-----BEGIN RSA PUBLIC KEY-----\n%@\n-----END RSA PUBLIC KEY-----\n", b64];
        WriteOutputPath(outPath, out_fd, [pem dataUsingEncoding:NSUTF8StringEncoding]);
    }

    if (doVerify || caFile) {
        NSArray *anchors = caFile ? LoadCertificatesFromData([NSData dataWithContentsOfFile:@(caFile)]) : @[];
        if (caFile && !anchors.count) {
            WriteStr(err_fd, @"Verification failure\n");
            return 1;
        }
        BOOL ok = VerifyTrustChain(certs, anchors, NO);
        if (!ok) {
            WriteStr(err_fd, @"Verification failure\n");
            return 1;
        }
        NSString *msg = isVerifyCmd ? [NSString stringWithFormat:@"%s: OK\n", inPath ?: "stdin"] : @"Verification successful\n";
        WriteOutputPath(outPath, out_fd, [msg dataUsingEncoding:NSUTF8StringEncoding]);
        return 0;
    }

    if (!noout && !wantPubkey) WriteOutputPath(outPath, out_fd, raw);
    return 0;
}

// MARK: - Dispatch entrypoint

int MacOpenSSLRun(int argc, const char *const *argv, int in_fd, int out_fd, int err_fd) {
    @autoreleasepool {
        if (argc < 2 || !argv || !argv[1]) {
            WriteStr(err_fd, @"openssl: missing subcommand\n");
            return 2;
        }
        const char *cmd = argv[1];
        if (!strcmp(cmd, "version") || !strcmp(cmd, "-v") || !strcmp(cmd, "--version")) {
            WriteStr(out_fd, @"OpenSSL 3.0.0 (Triptych Security.framework)\n");
            return 0;
        }
        if (!strcmp(cmd, "dgst")) {
            return RunDgst(argc, argv, 2, DigestSHA256, in_fd, out_fd, err_fd);
        }
        if (!strcmp(cmd, "sha1"))   return RunDgst(argc, argv, 2, DigestSHA1, in_fd, out_fd, err_fd);
        if (!strcmp(cmd, "sha256")) return RunDgst(argc, argv, 2, DigestSHA256, in_fd, out_fd, err_fd);
        if (!strcmp(cmd, "sha384")) return RunDgst(argc, argv, 2, DigestSHA384, in_fd, out_fd, err_fd);
        if (!strcmp(cmd, "sha512")) return RunDgst(argc, argv, 2, DigestSHA512, in_fd, out_fd, err_fd);
        if (!strcmp(cmd, "smime") || !strcmp(cmd, "cms")) {
            return RunSMIME(argc, argv, 2, in_fd, out_fd, err_fd);
        }
        if (!strcmp(cmd, "x509")) {
            return RunX509OrVerify(NO, argc, argv, 2, in_fd, out_fd, err_fd);
        }
        if (!strcmp(cmd, "verify")) {
            return RunX509OrVerify(YES, argc, argv, 2, in_fd, out_fd, err_fd);
        }
        WriteStr(err_fd, [NSString stringWithFormat:@"openssl: unsupported subcommand '%s'\n", cmd]);
        return 2;
    }
}
