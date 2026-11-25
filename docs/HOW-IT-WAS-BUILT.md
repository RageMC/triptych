# How Triptych was built: fully vibe coded

Every line of Triptych's own code, scripts and docs was written by AI. **RageMC** directed the project: the goals, the rules, what "done" means, and every decision that leaves the machine. The upstream engines it builds on were written by people (see [CREDITS.md](../CREDITS.md)).

## The system

- **Main model:** Claude Code with Claude Opus 5.5, in the Claude desktop app on an M1 Max Mac.
  - A main "lab" chat holds the user's rules and long-running context.
  - This project ran in its own session, started from that chat.
  - Sessions hand context over through shared notes and a handoff file when they fill up.
- **Subagents:** the project session hands self-contained pieces to helper agents and reviews and verifies each result before committing it. Pieces included the NVMe and USB controllers, ACPI debugging, TPM, Windows boot debugging and research. Routine code went to Claude Sonnet, lookups to Claude Haiku, and hard reasoning stayed on Opus.
- **Always-on runner:** a local task queue with self-continuing tasks keeps the project moving when no chat is open. It needs a clean repo and reads the "Not done yet" list in `docs/STATUS.md`.
- **Free-model research swarm:**
  - A script sends research questions to about 138 free and keyless models through a local proxy (freellmpool).
  - Every claimed quote and number is checked against the source text, and findings must be confirmed by more than one provider.
  - What survives goes into research notes (kept in the private repository).
- **Local model:** a Qwen 27B model running locally (MLX/Ollama) handles bulk low-judgement reading and drafting. A fan-out tool splits large reading jobs across free models and keeps only verified claims.
- **Antigravity (Gemini):** Google's agent CLI runs a second coding lane on Gemini 4 models, with each result verified before it is committed.
- **[TokenEconomizer](https://github.com/microsoft/TokenEconomizer)** (Microsoft, Apache-2.0): a Claude Code and Antigravity plugin that learns repo facts, prunes unused tools and redirects stuck loops, to cut token use.
- **Every user message** is also answered in parallel by fast free models, whose notes the main model checks before using.

## How work was checked

- Code-review passes over the whole repo. Each review found real bugs: JIT script conflicts, controller hosting, extension IDs, address-range races and ACPI table errors. Each was fixed and re-checked.
- Builds and tests:
  - Henge's own test suite runs after every engine patch.
  - Xcode UI tests run in the iOS Simulator: Linux download and boot, Home, and the macOS engine.
  - The Windows VM board (`engines/winvm`) runs on the Mac, against QEMU as the reference: EDK2, then Linux, then Windows.
- Usage pacing: the work is paced against the plan's 5-hour and weekly limits. Cheaper models handle routine work, so the project keeps going without hitting a limit.

## Rules the AI worked under

- No piracy or DRM bypass.
- Never enter credentials.
- Never download or bundle Apple or Windows images, keys or proprietary binaries.
- No pull requests, issues or comments on other people's repositories.
- Publish nothing without the user's OK.
- Mask private data before sending anything to free models.
- No interim builds handed over, except previews the owner asks for (0.1.0 is one), labelled as unfinished.
