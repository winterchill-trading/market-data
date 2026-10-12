open! Core
open! Async

module Entry = struct
  module Stable = struct
    module V1 = struct
      type t =
        { at : Time_ns.Stable.V1.t
        ; book : L2_update.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal]
    end
  end

  include Stable.V1
end

let digest = Bin_prot.Shape.eval_to_digest_string Entry.Stable.V1.bin_shape_t

let path ~dir instrument date =
  Store.stream_dir (Store.create dir) Norm instrument L2
  ^/ "_snapshots"
  ^/ Date.to_string date
  ^ ".bin"
;;

module Builder = struct
  type t =
    { interval : Time_ns.Span.t
    ; mutable book : L2_book.t
    ; mutable last_exch_ts : Time_ns.t
    ; mutable bucket : Time_ns.t option
    }

  let create ~interval =
    if Time_ns.Span.( <= ) interval Time_ns.Span.zero
    then
      raise_s
        [%message "Snapshot_index: interval must be positive" (interval : Time_ns.Span.t)];
    { interval; book = L2_book.empty; last_exch_ts = Time_ns.epoch; bucket = None }
  ;;

  let bucket_of t time =
    Time_ns.prev_multiple
      ~can_equal_before:true
      ~base:Time_ns.epoch
      ~before:time
      ~interval:t.interval
      ()
  ;;

  let observe t (u : L2_update.t) =
    let bucket = bucket_of t u.recv_ts in
    let entry =
      match t.bucket with
      | Some previous when Time_ns.( > ) bucket previous && L2_book.has_snapshot t.book ->
        Some
          { Entry.at = bucket
          ; book =
              { instrument = u.instrument
              ; exch_ts = t.last_exch_ts
              ; recv_ts = bucket
              ; kind = Snapshot
              ; bids = L2_book.bids t.book
              ; asks = L2_book.asks t.book
              }
          }
      | _ -> None
    in
    t.book <- L2_book.apply t.book u;
    t.last_exch_ts <- u.exch_ts;
    t.bucket <- Some bucket;
    entry
  ;;
end

let load ~dir instrument date =
  let path = path ~dir instrument date in
  match%bind Sys.file_exists_exn path with
  | false -> return []
  | true ->
    let%map entries, _tail = Framed.load_file ~digest Entry.bin_reader_t path in
    entries
;;

let find ~dir instrument time =
  let%map entries = load ~dir instrument (Store.date_of_time time) in
  List.fold entries ~init:None ~f:(fun found (e : Entry.t) ->
    if Time_ns.( <= ) e.at time then Some e else found)
;;
