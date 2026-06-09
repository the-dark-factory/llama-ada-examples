with Ada.Text_IO; use Ada.Text_IO;
with Llama;

--  llama-ada first light: load a small GGUF model and let Ada continue a
--  prompt, streaming the generated text to stdout via the forged wrapper.
procedure Run is
begin
   Put ("The capital of France is");
   Llama.Generate
     (Model_Path => "models/qwen2.5-0.5b-instruct-q4_k_m.gguf",
      Prompt     => "The capital of France is",
      Max_Tokens => 40);
   New_Line;
end Run;
