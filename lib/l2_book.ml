open! Core

type t =
  { bids : Size.t Price.Map.t
  ; asks : Size.t Price.Map.t
  ; has_snapshot : bool
  ; last_update : Time_ns.Alternate_sexp.t option
  }
[@@deriving sexp_of]

let empty =
  { bids = Price.Map.empty
  ; asks = Price.Map.empty
  ; has_snapshot = false
  ; last_update = None
  }
;;

let has_snapshot t = t.has_snapshot
let last_update t = t.last_update

let set side (level : L2_update.Level.t) =
  if Size.is_zero level.size
  then Map.remove side level.price
  else Map.set side ~key:level.price ~data:level.size
;;

let apply t (u : L2_update.t) =
  let bids, asks, has_snapshot =
    match u.kind with
    | Snapshot -> Price.Map.empty, Price.Map.empty, true
    | Delta -> t.bids, t.asks, t.has_snapshot
  in
  { bids = List.fold u.bids ~init:bids ~f:set
  ; asks = List.fold u.asks ~init:asks ~f:set
  ; has_snapshot
  ; last_update = Some u.recv_ts
  }
;;

let levels ?depth map ~order =
  let l =
    Map.to_sequence ~order map
    |> Sequence.map ~f:(fun (price, size) -> { L2_update.Level.price; size })
  in
  let l =
    match depth with
    | None -> l
    | Some n -> Sequence.take l n
  in
  Sequence.to_list l
;;

let bids ?depth t = levels ?depth t.bids ~order:`Decreasing_key
let asks ?depth t = levels ?depth t.asks ~order:`Increasing_key

let to_string_hum ?depth t =
  let rows side levels =
    List.map levels ~f:(fun (l : L2_update.Level.t) ->
      side, Price.to_string l.price, Size.to_string l.size)
  in
  let rows = rows "ask" (List.rev (asks ?depth t)) @ rows "bid" (bids ?depth t) in
  let width f = List.fold rows ~init:0 ~f:(fun acc r -> max acc (String.length (f r))) in
  let pw = width (fun (_, p, _) -> p) in
  List.map rows ~f:(fun (side, p, s) ->
    sprintf "%s  %s%s  %s\n" side (String.make (pw - String.length p) ' ') p s)
  |> String.concat
;;
