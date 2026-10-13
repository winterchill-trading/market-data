open! Core
open! Async

type 'a t =
  { path : string
  ; tmp : string
  ; writer : 'a Parquet.Writer.t
  ; add_row : 'a -> unit
  }

let path t = t.path

let create ?(compression = `Zstd) ?direct schema ~row_group_rows path =
  let tmp = path ^ ".tmp" in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  let%map writer =
    In_thread.run (fun () ->
      Parquet.Writer.create ~schema ~row_group_rows ~compression tmp)
  in
  let add_row =
    match direct with
    | Some direct -> direct writer
    | None -> Parquet.Writer.add writer
  in
  { path; tmp; writer; add_row }
;;

let add t rows =
  match rows with
  | [] -> return ()
  | rows -> In_thread.run (fun () -> List.iter rows ~f:t.add_row)
;;

let write t ~f = In_thread.run (fun () -> f t.writer)
let num_rows t = Parquet.Writer.num_rows t.writer

let close t =
  let%bind () = In_thread.run (fun () -> Parquet.Writer.close t.writer) in
  Unix.rename ~src:t.tmp ~dst:t.path
;;
