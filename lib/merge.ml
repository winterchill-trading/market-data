open! Core
open! Async

let sorted inputs ~compare =
  let inputs = Array.of_list inputs in
  let heap =
    Pairing_heap.create
      ~cmp:(fun (a, i) (b, j) ->
        match compare a b with
        | 0 -> Int.compare i j
        | c -> c)
      ()
  in
  let refill i =
    match%map Pipe.read inputs.(i) with
    | `Eof -> ()
    | `Ok v -> Pairing_heap.add heap (v, i)
  in
  let output =
    Pipe.create_reader ~close_on_exception:true (fun w ->
      let%bind () =
        Deferred.List.iter
          ~how:`Parallel
          (List.init (Array.length inputs) ~f:Fn.id)
          ~f:refill
      in
      let rec loop () =
        if Pipe.is_closed w
        then return ()
        else (
          match Pairing_heap.pop heap with
          | None -> return ()
          | Some (v, i) ->
            let%bind () = Pipe.write_if_open w v in
            let%bind () = refill i in
            loop ())
      in
      loop ())
  in
  upon (Pipe.closed output) (fun () -> Array.iter inputs ~f:Pipe.close_read);
  output
;;
