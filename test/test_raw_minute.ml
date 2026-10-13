open! Core
open Market_data

(* The parser before in-place parsing: split at the first space, copy both halves. *)
let reference_parse line : Raw_minute.Line.t Or_error.t =
  if String.is_empty line
  then Ok Disconnect
  else (
    match String.lsplit2 line ~on:' ' with
    | None -> Or_error.error_s [%message "Raw_minute: no space after the timestamp" line]
    | Some (ts, payload) ->
      (match Time_ns.of_string_with_utc_offset ts with
       | recv_ts -> Ok (Frame { recv_ts; payload })
       | exception _ ->
         Or_error.error_s [%message "Raw_minute: bad timestamp" (ts : string)]))
;;

let same line =
  [%test_result: Raw_minute.Line.t Or_error.t]
    (Raw_minute.Line.parse line)
    ~expect:(reference_parse line)
;;

(* Recorder-shaped timestamps with 0 to 9 fraction digits, over 1970 to 2099. *)
let gen_ts =
  let open Quickcheck.Let_syntax in
  let%bind ns =
    Int.gen_incl
      0
      (Time_ns.to_int_ns_since_epoch (Time_ns.of_string "2099-12-31 23:59:59Z"))
  and digits = Int.gen_incl 0 9 in
  let t = Time_ns.of_int_ns_since_epoch ns in
  let base = Time_ns.to_string_iso8601_basic t ~zone:Time_float.Zone.utc in
  (* [base] is [YYYY-MM-DDTHH:MM:SS.fffffffffZ]. *)
  let whole = String.prefix base 19 in
  let frac = String.sub base ~pos:20 ~len:digits in
  return (if digits = 0 then whole ^ "Z" else whole ^ "." ^ frac ^ "Z")
;;

let%test_unit "quickcheck: recorder timestamps parse as before" =
  Quickcheck.test ~sexp_of:String.sexp_of_t gen_ts ~f:(fun ts -> same (ts ^ " {\"x\":1}"))
;;

let%test_unit "quickcheck: mangled timestamps parse or fail as before" =
  let gen =
    let open Quickcheck.Let_syntax in
    let%bind ts = gen_ts in
    let%bind pos = Int.gen_incl 0 (String.length ts - 1) in
    let%map c = Char.quickcheck_generator in
    let b = Bytes.of_string ts in
    Bytes.set b pos c;
    Bytes.to_string b ^ " p"
  in
  Quickcheck.test ~sexp_of:String.sexp_of_t gen ~f:same
;;

let%expect_test "edge cases agree with the reference" =
  List.iter
    [ ""
    ; "no-space"
    ; " payload"
    ; "2026-01-01T00:00:00Z p"
    ; "2026-01-01T00:00:00.Z p"
    ; "2026-01-01T00:00:00.1234567891Z p"
    ; "2026-02-29T00:00:00Z p"
    ; "2024-02-29T23:59:59.999999999Z p"
    ; "2026-01-01T23:59:60Z p"
    ; "2026-01-01T00:00:00+01:00 p"
    ; "2026-01-01 00:00:00Z p"
    ; "1969-12-31T23:59:59Z p"
    ; "2026-13-01T00:00:00Z p"
    ; "2026-01-01T00:00:00.000001Z a b c"
    ; "2026-01-01T00:00:00.000001Z "
    ]
    ~f:(fun line ->
      same line;
      print_s [%sexp (Raw_minute.Line.parse line : Raw_minute.Line.t Or_error.t)]);
  [%expect
    {|
    (Ok Disconnect)
    (Error ("Raw_minute: no space after the timestamp" no-space))
    (Error ("Raw_minute: bad timestamp" (ts "")))
    (Ok (Frame (recv_ts "2026-01-01 00:00:00Z") (payload p)))
    (Ok (Frame (recv_ts "2026-01-01 00:00:00Z") (payload p)))
    (Ok (Frame (recv_ts "2026-01-01 00:00:00.123456789Z") (payload p)))
    (Error ("Raw_minute: bad timestamp" (ts 2026-02-29T00:00:00Z)))
    (Ok (Frame (recv_ts "2024-02-29 23:59:59.999999999Z") (payload p)))
    (Ok (Frame (recv_ts "2026-01-02 00:00:00Z") (payload p)))
    (Ok (Frame (recv_ts "2025-12-31 23:00:00Z") (payload p)))
    (Error ("Raw_minute: bad timestamp" (ts 2026-01-01)))
    (Ok (Frame (recv_ts "1969-12-31 23:59:59Z") (payload p)))
    (Error ("Raw_minute: bad timestamp" (ts 2026-13-01T00:00:00Z)))
    (Ok (Frame (recv_ts "2026-01-01 00:00:00.000001Z") (payload "a b c")))
    (Ok (Frame (recv_ts "2026-01-01 00:00:00.000001Z") (payload "")))
    |}]
;;

let%expect_test "iter_text agrees with parsing each split line" =
  let text =
    "2026-01-01T00:00:01.5Z a\n\nbad\n2026-01-01T00:00:02Z b c\n2026-01-01T00:00:03Z"
  in
  let got = ref [] in
  Raw_minute.iter_text
    text
    ~frame:(fun ~recv_ts ~payload ->
      got := Ok (Raw_minute.Line.Frame { recv_ts; payload }) :: !got)
    ~disconnect:(fun () -> got := Ok Raw_minute.Line.Disconnect :: !got)
    ~error:(fun e -> got := Error e :: !got);
  [%test_result: Raw_minute.Line.t Or_error.t list]
    (List.rev !got)
    ~expect:(String.split text ~on:'\n' |> List.map ~f:reference_parse);
  List.iter (List.rev !got) ~f:(fun l ->
    print_s [%sexp (l : Raw_minute.Line.t Or_error.t)]);
  [%expect
    {|
    (Ok (Frame (recv_ts "2026-01-01 00:00:01.5Z") (payload a)))
    (Ok Disconnect)
    (Error ("Raw_minute: no space after the timestamp" bad))
    (Ok (Frame (recv_ts "2026-01-01 00:00:02Z") (payload "b c")))
    (Error ("Raw_minute: no space after the timestamp" 2026-01-01T00:00:03Z))
    |}]
;;
