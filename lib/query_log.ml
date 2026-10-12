open! Core
open! Async

let path ~dir = dir ^/ "query-log.ndjson"

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter s ~f:(fun c ->
    match c with
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | '\r' -> Buffer.add_string b "\\r"
    | '\t' -> Buffer.add_string b "\\t"
    | c when Char.to_int c < 0x20 ->
      Buffer.add_string b (sprintf "\\u%04x" (Char.to_int c))
    | c -> Buffer.add_char b c);
  Buffer.add_char b '"';
  Buffer.contents b
;;

let entry ~time ~user ~sql =
  sprintf
    "{\"time\":%s,\"user\":%s,\"sql\":%s}"
    (json_string (Time_ns.to_string_iso8601_basic time ~zone:Time_float.Zone.utc))
    (json_string user)
    (json_string sql)
;;

let current_user () =
  List.find_map [ "USER"; "LOGNAME" ] ~f:(fun var ->
    Option.filter (Sys.getenv var) ~f:(Fn.non String.is_empty))
  |> Option.value ~default:"unknown"
;;

let append ?(time = Time_ns.now ()) ?(user = current_user ()) ~dir sql =
  Writer.with_file ~append:true (path ~dir) ~f:(fun w ->
    Writer.write_line w (entry ~time ~user ~sql);
    return ())
;;
