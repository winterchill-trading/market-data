open! Core

module Barriers = struct
  type t =
    { profit_take : float option
    ; stop_loss : float option
    ; vertical : Time_ns.Span.t option
    }
  [@@deriving sexp, compare, equal]
end

module Event = struct
  type t =
    { index : int
    ; width : float
    ; side : Side.t option
    }
  [@@deriving sexp, compare, equal]
end

module Barrier = struct
  type t =
    | Profit_take
    | Stop_loss
    | Vertical
    | End_of_data
  [@@deriving sexp, compare, equal, enumerate]
end

module Label = struct
  type t =
    { index : int
    ; exit_index : int
    ; entry_time : Time_ns.t
    ; exit_time : Time_ns.t
    ; entry_price : float
    ; exit_price : float
    ; barrier : Barrier.t
    ; return : float
    ; label : int
    }
  [@@deriving sexp, compare, equal]
end

let sign x = if Float.( > ) x 0. then 1 else if Float.( < ) x 0. then -1 else 0

let label1 ~times ~prices (b : Barriers.t) (e : Event.t) : Label.t =
  let n = Array.length prices in
  if e.index < 0 || e.index >= n
  then raise_s [%message "Labels.label: event index outside the series" (e : Event.t)];
  if (Option.is_some b.profit_take || Option.is_some b.stop_loss)
     && not (Float.is_finite e.width && Float.( > ) e.width 0.)
  then raise_s [%message "Labels.label: event width must be positive" (e : Event.t)];
  let entry = prices.(e.index) in
  let entry_time = times.(e.index) in
  let direction =
    match e.side with
    | None | Some Buy -> 1.
    | Some Sell -> -1.
  in
  (* Barriers on the bet's return [direction * (p / entry - 1)]. *)
  let profit = Option.map b.profit_take ~f:(fun m -> m *. e.width) in
  let stop = Option.map b.stop_loss ~f:(fun m -> -.(m *. e.width)) in
  let horizon = Option.map b.vertical ~f:(Time_ns.add entry_time) in
  let return_at j = direction *. ((prices.(j) /. entry) -. 1.) in
  let finish j barrier : Label.t =
    let return = return_at j in
    let label =
      match e.side, barrier with
      | Some _, _ -> if Float.( > ) return 0. then 1 else 0
      | None, Barrier.Profit_take -> 1
      | None, Stop_loss -> -1
      | None, (Vertical | End_of_data) -> sign return
    in
    { index = e.index
    ; exit_index = j
    ; entry_time
    ; exit_time = times.(j)
    ; entry_price = entry
    ; exit_price = prices.(j)
    ; barrier
    ; return
    ; label
    }
  in
  let rec scan j =
    if j >= n
    then finish (n - 1) End_of_data
    else (
      match horizon with
      | Some h when Time_ns.( > ) times.(j) h -> finish (j - 1) Vertical
      | _ ->
        let r = return_at j in
        (match profit, stop with
         | Some p, _ when Float.( >= ) r p -> finish j Profit_take
         | _, Some s when Float.( <= ) r s -> finish j Stop_loss
         | _ -> scan (j + 1)))
  in
  scan (e.index + 1)
;;

let label ~times ~prices barriers events =
  if Array.length times <> Array.length prices
  then
    raise_s
      [%message
        "Labels.label: times and prices differ in length"
          ~times:(Array.length times : int)
          ~prices:(Array.length prices : int)];
  List.map events ~f:(label1 ~times ~prices barriers)
;;

let ewma_volatility ~prices ~span =
  if span < 1
  then raise_s [%message "Labels.ewma_volatility: span must be >= 1" (span : int)];
  let alpha = 2. /. Float.of_int (span + 1) in
  let n = Array.length prices in
  let out = Array.create ~len:n Float.nan in
  let var = ref Float.nan in
  for k = 1 to n - 1 do
    let r = (prices.(k) /. prices.(k - 1)) -. 1. in
    var
    := if Float.is_nan !var then r *. r else ((1. -. alpha) *. !var) +. (alpha *. r *. r);
    out.(k) <- Float.sqrt !var
  done;
  out
;;
