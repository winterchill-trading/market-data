open! Core
open! Async
open Market_data

let%expect_test "entries are one escaped json object per line" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = Query_log.append ~time:(Sample.ts 0) ~user:"alice" ~dir "SELECT 1" in
    let%bind () =
      Query_log.append
        ~time:(Sample.ts 1_500)
        ~user:"bob"
        ~dir
        "SELECT 'a\"b'\nFROM trades\t-- \\ done"
    in
    let%bind contents = Reader.file_contents (Query_log.path ~dir) in
    print_string contents;
    [%expect
      {|
      {"time":"2026-01-01T00:00:00.000000000Z","user":"alice","sql":"SELECT 1"}
      {"time":"2026-01-01T00:00:01.500000000Z","user":"bob","sql":"SELECT 'a\"b'\nFROM trades\t-- \\ done"}
      |}];
    return ())
;;
