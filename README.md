# llama-ada-examples

Examples for **df_llama** — the Ada binding to [llama.cpp](https://github.com/ggml-org/llama.cpp),
i.e. running a local LLM from Ada.

## Examples

- **`examples/run`** — first light: load a GGUF model and let Ada continue a prompt,
  streaming the generated text.
- **`examples/mind`** — the *mind-watcher*: chat with a local model where each word
  is shaded by how *sure* the model was when it chose it — bright = certain,
  faint = torn, orange = it sampled a road that wasn't the top one (high
  temperature). A background task repaints `mind.svg` every 20s for an ambient
  glance; `/verbose` prints the full per-token table.

  The signal is honest about what it is: "sure" means the top token's
  probability was high — how *settled* the choice was — **not** that it was
  *right*. A model can be sure and wrong, or torn and right; this shows where it
  had options.

## Build & run

You need a C/C++ toolchain, a built llama.cpp, and a small GGUF model.

1. Build [llama.cpp](https://github.com/ggml-org/llama.cpp) and point
   `LLAMA_CPP_LIB` at the directory holding its libraries.
2. Fetch a model into `models/`, e.g. `qwen2.5-0.5b-instruct-q4_k_m.gguf`.
3. From the crate root:

   ```sh
   alr build                      # pulls in df_llama
   ./examples/run/bin/run         # first light
   ./examples/mind/bin/mind       # the mind-watcher
   ```

## License

Apache-2.0. © 2026 The Dark Factory Ltd.
