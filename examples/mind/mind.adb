with Interfaces.C;                     use Interfaces.C;
with Interfaces.C.Strings;
with System;
with Ada.Text_IO;                       use Ada.Text_IO;
with Ada.Unchecked_Conversion;
with Ada.Numerics.Elementary_Functions; use Ada.Numerics.Elementary_Functions;
with Ada.Numerics.Float_Random;
with Ada.Real_Time;
with sys_utypes_uint32_t_h;
with llama_h;

--  mind -- the mind-watcher (v1.1, readable).
--
--  Chat with a local model. The reply reads as normal text, but each word is
--  SHADED by how sure the model was when it chose it: bright = certain, faint
--  = torn, orange = it sampled a road that wasn't the top one (high temp). So
--  you read what it said AND see where it hesitated, in one stream. A
--  background task repaints `mind.svg` every 20s from the same numbers -- the
--  ambient glance. `/verbose` shows the full per-token table.
--
--  Honest about the signal: "sure" means the top token's probability was high
--  -- how *settled* the choice was -- NOT that it was right. It can be sure and
--  wrong, or torn and right. It shows where it had options.
procedure Mind is

   package Rand renames Ada.Numerics.Float_Random;
   subtype Int32 is sys_utypes_uint32_t_h.int32_t;

   function To_Chars_Ptr is new Ada.Unchecked_Conversion
     (System.Address, Interfaces.C.Strings.chars_ptr);

   Model_Path  : constant String := "models/qwen2.5-0.5b-instruct-q4_k_m.gguf";
   Max_Tokens  : constant := 200;
   Temperature : Float   := 0.0;
   Verbose     : Boolean := False;

   ESC   : constant Character := Character'Val (27);
   Reset : constant String    := ESC & "[0m";

   type Token_Array is array (Natural range <>) of aliased llama_h.llama_token;
   type Logit_Array is array (Natural range <>) of aliased Float;

   Tok_Cap : constant := 4096;

   M_Params : llama_h.llama_model_params;
   C_Params : llama_h.llama_context_params;
   Model    : access llama_h.llama_model;
   Ctx      : access llama_h.llama_context;
   Vocab    : access constant llama_h.llama_vocab;
   Path_C   : Interfaces.C.Strings.chars_ptr :=
     Interfaces.C.Strings.New_String (Model_Path);

   Tokens  : aliased Token_Array (0 .. Tok_Cap - 1);
   Single  : aliased llama_h.llama_token := 0;
   Piece   : aliased Interfaces.C.char_array (0 .. 255);
   N_Vocab : Int32;
   Gen     : Rand.Generator;

   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;

   function Piece_Text (Id : llama_h.llama_token) return String is
      NP : constant Int32 := llama_h.llama_token_to_piece
             (Vocab, Id, To_Chars_Ptr (Piece'Address), Int32 (Piece'Length), 0, True);
   begin
      if NP <= 0 then
         return "";
      end if;
      declare
         S : String (1 .. Integer (NP));
      begin
         for J in S'Range loop
            S (J) := Interfaces.C.To_Ada (Piece (size_t (J - 1)));
         end loop;
         return S;
      end;
   end Piece_Text;

   --  Quote-and-flatten a piece for the verbose table only.
   function Show (S : String) return String is
      R : String := S;
   begin
      for I in R'Range loop
         if R (I) = ASCII.LF then
            R (I) := '/';
         end if;
      end loop;
      return "'" & R & "'";
   end Show;

   --  ANSI shade for a token from its confidence (top-token probability) and
   --  whether it was a sampled non-top road.
   function Shade (Conf : Float; Road : Boolean) return String is
   begin
      if Road then
         return ESC & "[38;5;208m";   --  orange: wandered off the top
      elsif Conf >= 0.8 then
         return ESC & "[1;97m";       --  bright bold: sure
      elsif Conf >= 0.4 then
         return ESC & "[0;37m";       --  plain: middling
      else
         return ESC & "[2;37m";       --  faint: torn
      end if;
   end Shade;

   --------------------------------------------------------------------------
   --  The pulse: a rolling log shared between the generator and the painter.
   --------------------------------------------------------------------------
   type Event is record
      Stamp  : Ada.Real_Time.Time;
      Peaked : Float;
      Road   : Boolean;
   end record;

   Ring_Cap : constant := 4096;
   type Event_Arr is array (0 .. Ring_Cap - 1) of Event;

   protected Pulse is
      procedure Record_Tok (Peaked : Float; Road : Boolean);
      procedure Snapshot (Out_Buf : out Event_Arr; N : out Natural);
   private
      Ring  : Event_Arr;
      Count : Natural := 0;
   end Pulse;

   protected body Pulse is
      procedure Record_Tok (Peaked : Float; Road : Boolean) is
      begin
         Ring (Count mod Ring_Cap) := (Ada.Real_Time.Clock, Peaked, Road);
         Count := Count + 1;
      end Record_Tok;

      procedure Snapshot (Out_Buf : out Event_Arr; N : out Natural) is
         use Ada.Real_Time;
         Now    : constant Time      := Clock;
         Window : constant Time_Span := To_Time_Span (20.0);
         Avail  : constant Natural   := Natural'Min (Count, Ring_Cap);
         Idx    : Natural            := 0;
      begin
         for K in 0 .. Avail - 1 loop
            declare
               E : Event renames Ring ((Count - Avail + K) mod Ring_Cap);
            begin
               if Now - E.Stamp <= Window then
                  Out_Buf (Idx) := E;
                  Idx := Idx + 1;
               end if;
            end;
         end loop;
         N := Idx;
      end Snapshot;
   end Pulse;

   procedure Render is
      Snap       : Event_Arr;
      N          : Natural;
      F          : File_Type;
      Sum_Peaked : Float   := 0.0;
      Roads      : Natural := 0;
   begin
      Pulse.Snapshot (Snap, N);
      begin
         Create (F, Out_File, "mind.svg");
      exception
         when others => return;
      end;
      Put_Line (F, "<svg xmlns='http://www.w3.org/2000/svg' width='820' height='430'>");
      if N = 0 then
         Put_Line (F, "<rect width='820' height='430' fill='#2a2a2e'/>");
         Put_Line (F, "<text x='410' y='215' fill='#666' font-family='monospace'"
                     & " font-size='22' text-anchor='middle'>idle</text>");
      else
         for I in 0 .. N - 1 loop
            Sum_Peaked := Sum_Peaked + Snap (I).Peaked;
            if Snap (I).Road then
               Roads := Roads + 1;
            end if;
         end loop;
         declare
            Avg : constant Float := Sum_Peaked / Float (N);
            Bg  : constant String :=
              (if Avg > 0.6 then "#0d1b2a"
               elsif Avg > 0.35 then "#1b1b2e"
               else "#2a1717");
         begin
            Put_Line (F, "<rect width='820' height='430' fill='" & Bg & "'/>");
            for I in 0 .. N - 1 loop
               declare
                  Sp  : constant Float   := 1.0 - Snap (I).Peaked;
                  X   : constant Integer :=
                    50 + Integer (Float (I) / Float (Integer'Max (N - 1, 1)) * 720.0);
                  Y   : constant Integer :=
                    205 + Integer (Float ((I * 97) mod 200 - 100) * Sp);
                  Rr  : constant Integer := 3 + Integer (Sp * 22.0);
                  Col : constant String  :=
                    (if Snap (I).Road then "#e08a3c" else "#4a90d9");
                  Op  : constant String  :=
                    (if Snap (I).Road then "0.7" else "0.45");
               begin
                  Put_Line (F, "<circle cx='" & Img (X) & "' cy='" & Img (Y)
                              & "' r='" & Img (Rr) & "' fill='" & Col
                              & "' opacity='" & Op & "'/>");
               end;
            end loop;
            Put_Line (F, "<text x='50' y='415' fill='#888' font-family='monospace'"
                        & " font-size='13'>last 20s &#183; " & Img (N)
                        & " tokens &#183; avg sure " & Img (Integer (Avg * 100.0))
                        & "% &#183; " & Img (Roads) & " roads taken</text>");
         end;
      end if;
      Put_Line (F, "</svg>");
      Close (F);
   end Render;

   task Heartbeat is
      entry Stop;
   end Heartbeat;

   task body Heartbeat is
      use Ada.Real_Time;
      Next : Time := Clock + To_Time_Span (20.0);
   begin
      loop
         select
            accept Stop;
            exit;
         or
            delay until Next;
            Render;
            Next := Next + To_Time_Span (20.0);
         end select;
      end loop;
   end Heartbeat;

   --  Generate a reply for the prompt at Tokens (0 .. N_Prompt-1). Default:
   --  stream it as readable text shaded by certainty. Verbose: the per-token
   --  table. Either way, record each token into the pulse for the picture.
   procedure Respond (N_Prompt : Int32) is
      Batch     : llama_h.llama_batch;
      Cur_Ptr   : access llama_h.llama_token := Tokens (0)'Access;
      Cur_Count : Int32 := N_Prompt;
      New_Id    : llama_h.llama_token;
   begin
      if Verbose then
         Put_Line ("  step  conf  token             roads not taken (raw %)");
      else
         Put ("  ");
      end if;

      for Step in 1 .. Max_Tokens loop
         Batch := llama_h.llama_batch_get_one (Cur_Ptr, Cur_Count);
         exit when llama_h.llama_decode (Ctx, Batch) /= 0;

         declare
            LP : constant access Float := llama_h.llama_get_logits_ith (Ctx, -1);
         begin
            exit when LP = null;
            declare
               Logits : Logit_Array (0 .. Natural (N_Vocab) - 1)
                          with Import, Address => LP.all'Address;
               Max_L : Float   := Logits (Logits'First);
               Arg   : Natural := Logits'First;
               Denom : Float   := 0.0;
               Top_L : array (1 .. 5) of Float   := (others => Float'First);
               Top_I : array (1 .. 5) of Natural := (others => 0);
               Pick  : Natural;
            begin
               for I in Logits'Range loop
                  if Logits (I) > Max_L then
                     Max_L := Logits (I);
                     Arg   := I;
                  end if;
               end loop;

               for I in Logits'Range loop
                  declare
                     W : constant Float := Exp (Logits (I) - Max_L);
                  begin
                     Denom := Denom + W;
                     if Logits (I) > Top_L (5) then
                        for K in 1 .. 5 loop
                           if Logits (I) > Top_L (K) then
                              for M in reverse K .. 4 loop
                                 Top_L (M + 1) := Top_L (M);
                                 Top_I (M + 1) := Top_I (M);
                              end loop;
                              Top_L (K) := Logits (I);
                              Top_I (K) := I;
                              exit;
                           end if;
                        end loop;
                     end if;
                  end;
               end loop;

               if Temperature <= 0.0 then
                  Pick := Arg;
               else
                  declare
                     TDen : Float := 0.0;
                     R, C : Float;
                  begin
                     for I in Logits'Range loop
                        TDen := TDen + Exp ((Logits (I) - Max_L) / Temperature);
                     end loop;
                     R    := Float (Rand.Random (Gen)) * TDen;
                     C    := 0.0;
                     Pick := Arg;
                     for I in Logits'Range loop
                        C := C + Exp ((Logits (I) - Max_L) / Temperature);
                        if C >= R then
                           Pick := I;
                           exit;
                        end if;
                     end loop;
                  end;
               end if;

               New_Id := llama_h.llama_token (Pick);
               exit when llama_h.llama_vocab_is_eog (Vocab, New_Id);

               declare
                  Conf : constant Float   := 1.0 / Denom;   --  top-token probability
                  Road : constant Boolean := Pick /= Arg;
               begin
                  Pulse.Record_Tok (Conf, Road);
                  if Verbose then
                     Put ("  " & Img (Step));
                     Set_Col (8);
                     Put (Img (Integer (Conf * 100.0)) & "%");
                     Set_Col (14);
                     Put (Show (Piece_Text (New_Id)));
                     Set_Col (32);
                     for K in 1 .. 5 loop
                        Put (Show (Piece_Text (llama_h.llama_token (Top_I (K)))) & "="
                             & Img (Integer ((Exp (Top_L (K) - Max_L) / Denom) * 100.0))
                             & " ");
                     end loop;
                     New_Line;
                  else
                     Put (Shade (Conf, Road) & Piece_Text (New_Id) & Reset);
                     Flush;
                  end if;
               end;
            end;
         end;

         Single    := New_Id;
         Cur_Ptr   := Single'Access;
         Cur_Count := 1;
      end loop;
      New_Line;
      if not Verbose then
         New_Line;
      end if;
   end Respond;

   Line : String (1 .. 4096);
   Last : Natural;
begin
   Rand.Reset (Gen);
   llama_h.llama_backend_init;
   M_Params := llama_h.llama_model_default_params;
   Model := llama_h.llama_model_load_from_file (Path_C, M_Params);
   if Model = null then
      raise Program_Error;
   end if;
   Vocab   := llama_h.llama_model_get_vocab (Model);
   N_Vocab := llama_h.llama_vocab_n_tokens (Vocab);
   C_Params := llama_h.llama_context_default_params;
   Ctx := llama_h.llama_init_from_model (Model, C_Params);
   if Ctx = null then
      raise Program_Error;
   end if;

   Render;

   New_Line;
   Put_Line ("mind-watcher -- chat with a local model. The reply is shaded by how");
   Put_Line ("sure it was of each word:");
   Put_Line ("  " & ESC & "[1;97msure" & Reset & "   "
             & ESC & "[0;37mmiddling" & Reset & "   "
             & ESC & "[2;37mtorn" & Reset & "   "
             & ESC & "[38;5;208mwandered (high temp)" & Reset);
   Put_Line ("  '/temp 0.8' temperature   '/verbose' per-token table   '/quit' leave");
   Put_Line ("  Open mind.svg for the ambient 20s glance.");

   loop
      New_Line;
      Put ("you> ");
      begin
         Get_Line (Line, Last);
      exception
         when End_Error =>
            exit;
      end;

      declare
         Input : constant String := Line (1 .. Last);
      begin
         exit when Input = "/quit";
         if Input = "/verbose" then
            Verbose := not Verbose;
            Put_Line ("  verbose " & (if Verbose then "on (per-token table)"
                                      else "off (readable reply)"));
         elsif Input'Length >= 6
           and then Input (Input'First .. Input'First + 5) = "/temp "
         then
            begin
               Temperature := Float'Value (Input (Input'First + 6 .. Input'Last));
               Put_Line ("  temperature = " & Temperature'Image);
            exception
               when others =>
                  Put_Line ("  ? couldn't read a number");
            end;
         elsif Input /= "" then
            declare
               Turn : constant String :=
                 "<|im_start|>user" & ASCII.LF & Input & "<|im_end|>" & ASCII.LF
                 & "<|im_start|>assistant" & ASCII.LF;
               Turn_C : Interfaces.C.Strings.chars_ptr :=
                 Interfaces.C.Strings.New_String (Turn);
               N_Tok  : Int32;
            begin
               N_Tok := llama_h.llama_tokenize
                          (Vocab, Turn_C, Int32 (Turn'Length),
                           Tokens (0)'Access, Int32 (Tok_Cap), False, True);
               Interfaces.C.Strings.Free (Turn_C);
               if N_Tok > 0 then
                  Respond (N_Tok);
               end if;
            end;
         end if;
      end;
   end loop;

   Heartbeat.Stop;
   New_Line;
   Put_Line ("bye.");
   llama_h.llama_free (Ctx);
   llama_h.llama_model_free (Model);
   llama_h.llama_backend_free;
   Interfaces.C.Strings.Free (Path_C);
end Mind;
