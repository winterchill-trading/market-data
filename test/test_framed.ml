open! Core
open! Async
open Market_data

let string_writer = String.bin_writer_t
let string_reader = String.bin_reader_t

let%test_unit "quickcheck: random flush and buffer sizes read back identical" =
  let gen =
    let open Quickcheck.Generator.Let_syntax in
    let payload =
      let%bind len = Int.gen_log_uniform_incl 0 5_000 in
      String.gen_with_length len Char.quickcheck_generator
    in
    let gen =
      let%map payloads =
        let%bind n = Int.gen_incl 0 60 in
        List.gen_with_length n payload
      and flush_bytes = Int.gen_log_uniform_incl 1 20_000
      and buf_len = Int.gen_log_uniform_incl 1 20_000
      and flush_every = Int.gen_incl 1 10 in
      payloads, flush_bytes, buf_len, flush_every
    in
    gen
  in
  Quickcheck.test
    ~trials:100
    gen
    ~sexp_of:[%sexp_of: string list * int * int * int]
    ~f:(fun (payloads, flush_bytes, buf_len, flush_every) ->
      let read =
        Thread_safe.block_on_async_exn (fun () ->
          Sample.with_temp_dir (fun dir ->
            let path = dir ^/ "f.bin" in
            let w =
              Framed.Writer.create
                ~flush_bytes
                ~digest:(String.make 32 'a')
                string_writer
                ~path_for_date:(fun _ -> path)
                ()
            in
            let%bind () =
              Deferred.List.iteri ~how:`Sequential payloads ~f:(fun i p ->
                Framed.Writer.append w p ~time:(Sample.ts 0);
                if i % flush_every = 0 then Framed.Writer.flush w else Deferred.unit)
            in
            let%bind () = Framed.Writer.close w in
            match%bind Sys.file_exists_exn path with
            | false -> return ([], Framed.Tail.Clean)
            | true -> Framed.load_file ~buf_len string_reader path))
      in
      [%test_result: string list * Framed.Tail.t] read ~expect:(payloads, Clean))
;;

let%expect_test "minor words per appended frame" =
  Sample.with_temp_dir (fun dir ->
    let path = dir ^/ "f.bin" in
    let w =
      Framed.Writer.create
        ~flush_bytes:(1 lsl 30)
        Event.bin_writer_t
        ~path_for_date:(fun _ -> path)
        ()
    in
    let event = Event.Trade (Sample.trade ~ms:0 ~price:"100" ~size:"1" ()) in
    let time = Sample.ts 0 in
    let n = 10_000 in
    (* Warm up so buffer growth is amortised out. *)
    for _ = 1 to n do
      Framed.Writer.append w event ~time
    done;
    let before = Gc.minor_words () in
    for _ = 1 to n do
      Framed.Writer.append w event ~time
    done;
    let words = (Gc.minor_words () - before) / n in
    printf "append: %d words per frame\n" words;
    let%bind () = Framed.Writer.close w in
    let before = Gc.minor_words () in
    let%bind events, _ = Framed.load_file Event.bin_reader_t path in
    let words = (Gc.minor_words () - before) / List.length events in
    (* Mostly the decoded event and pipe bookkeeping; was 326 before buffers were reused. *)
    printf
      "read: %d frames, under 310 words per frame: %b\n"
      (List.length events)
      (words < 310);
    [%expect
      {|
      append: 0 words per frame
      read: 20000 frames, under 310 words per frame: true
      |}];
    return ())
;;
