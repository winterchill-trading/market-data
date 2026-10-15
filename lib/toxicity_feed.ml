open! Core
open! Async

let of_trades ~config trades =
  let states = Instrument.Table.create () in
  let state instrument =
    match Hashtbl.find states instrument with
    | Some s -> s
    | None ->
      let s = Option.map (config instrument) ~f:(Toxicity.create instrument) in
      Hashtbl.set states ~key:instrument ~data:s;
      s
  in
  Pipe.create_reader ~close_on_exception:true (fun w ->
    let%bind () =
      Pipe.iter' trades ~f:(fun chunk ->
        if Pipe.is_closed w
        then (
          Pipe.close_read trades;
          return ())
        else (
          Queue.iter chunk ~f:(fun (trade : Trade.t) ->
            match state trade.instrument with
            | None -> ()
            | Some s ->
              (match Toxicity.add s trade with
               | [] -> ()
               | events -> List.iter events ~f:(Pipe.write_without_pushback w)));
          Pipe.pushback w))
    in
    if not (Pipe.is_closed w)
    then
      (* In instrument order, so a replay gives the same pipe every time. *)
      Hashtbl.to_alist states
      |> List.sort ~compare:(fun (a, _) (b, _) -> Instrument.compare a b)
      |> List.iter ~f:(fun (_, s) ->
        Option.iter s ~f:(fun s ->
          List.iter (Toxicity.flush s) ~f:(Pipe.write_without_pushback w)));
    return ())
;;

let of_feed ~config (module F : Feed.S) = of_trades ~config F.trades
