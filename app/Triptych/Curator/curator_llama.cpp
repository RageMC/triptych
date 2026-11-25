// SPDX-License-Identifier: GPL-3.0-or-later
#include "curator_llama.h"
#include "llama.h"
#include <TargetConditionals.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
#include <string>

namespace {
struct Cancellation {
    bool (*should_continue)(void *);
    void *state;
};
}

bool curator_llama_generate(const char *path, const char *prompt,
                            bool (*should_continue)(void *), void *state,
                            char *output, size_t capacity) {
    // llama.cpp diagnostics can include local paths. Keep those out of Provenance.
    llama_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    llama_backend_init();
    Cancellation cancellation{should_continue, state};
    auto model_params = llama_model_default_params();
#if !TARGET_OS_SIMULATOR
    model_params.n_gpu_layers = 99;
#endif
    model_params.progress_callback = [](float, void *opaque) {
        const auto &cancel = *static_cast<Cancellation *>(opaque);
        return cancel.should_continue(cancel.state);
    };
    model_params.progress_callback_user_data = &cancellation;

    std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
        llama_model_load_from_file(path, model_params), llama_model_free);
    if (!model || !should_continue(state)) return false;

    constexpr int prompt_limit = 1408;
    constexpr int response_limit = 128;
    constexpr int batch_size = 32;
    const auto *vocab = llama_model_get_vocab(model.get());
    std::array<llama_token, prompt_limit> tokens;
    const int count = llama_tokenize(vocab, prompt, std::strlen(prompt),
                                     tokens.data(), tokens.size(), false, true);
    if (count <= 0) return false;

    auto context_params = llama_context_default_params();
    context_params.n_ctx = 1536;
    context_params.n_batch = batch_size;
    context_params.n_ubatch = batch_size;
    context_params.n_threads = 4;
    context_params.n_threads_batch = 4;
    std::unique_ptr<llama_context, decltype(&llama_free)> context(
        llama_init_from_model(model.get(), context_params), llama_free);
    if (!context) return false;
    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_init_greedy(), llama_sampler_free);
    if (!sampler) return false;

    for (int offset = 0; offset < count; offset += batch_size) {
        if (!should_continue(state)) return false;
        const auto batch = llama_batch_get_one(tokens.data() + offset, std::min(batch_size, count - offset));
        if (llama_decode(context.get(), batch) != 0) return false;
    }

    std::string result;
    for (int i = 0; i < response_limit; ++i) {
        if (!should_continue(state)) return false;
        auto token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) break;
        std::array<char, 512> piece;
        const int length = llama_token_to_piece(vocab, token, piece.data(), piece.size(), 0, false);
        if (length < 0) return false;
        result.append(piece.data(), length);
        if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0) return false;
    }
    if (result.empty() || result.size() >= capacity) return false;
    std::memcpy(output, result.c_str(), result.size() + 1);
    return true;
}
