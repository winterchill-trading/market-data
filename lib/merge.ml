open! Core
open! Async

(* A binary min-heap of input indices. Each input with buffered values has exactly one
   slot, so the heap never holds more than [Array.length inputs] entries and never
   allocates after creation. [less i j] orders the head values of inputs [i] and [j]. *)
module Index_heap = struct
  type t =
    { slots : int array
    ; mutable size : int
    ; less : int -> int -> bool
    }

  let create ~capacity ~less = { slots = Array.create ~len:capacity 0; size = 0; less }
  let is_empty t = t.size = 0

  let rec sift_up t pos =
    if pos > 0
    then (
      let parent = (pos - 1) / 2 in
      let x = t.slots.(pos) in
      let p = t.slots.(parent) in
      if t.less x p
      then (
        t.slots.(pos) <- p;
        t.slots.(parent) <- x;
        sift_up t parent))
  ;;

  let rec sift_down t pos =
    let l = (2 * pos) + 1 in
    if l < t.size
    then (
      let r = l + 1 in
      let c = if r < t.size && t.less t.slots.(r) t.slots.(l) then r else l in
      let x = t.slots.(pos) in
      let y = t.slots.(c) in
      if t.less y x
      then (
        t.slots.(pos) <- y;
        t.slots.(c) <- x;
        sift_down t c))
  ;;

  let add t i =
    t.slots.(t.size) <- i;
    t.size <- t.size + 1;
    sift_up t (t.size - 1)
  ;;

  (* Removes and returns the smallest index. *)
  let pop_exn t =
    let top = t.slots.(0) in
    t.size <- t.size - 1;
    if t.size > 0
    then (
      t.slots.(0) <- t.slots.(t.size);
      sift_down t 0);
    top
  ;;
end

(* Each input's buffered values come from one [Pipe.read'] batch of at most [batch_size].
   The merge runs synchronously over the buffers until one runs dry, writes what it
   produced as one batch, then reads that input again. Only the input that ran dry is
   read: its next value may sort before every buffered one. [set_head i v] records [v] as
   input [i]'s head; [less buffers] orders two inputs by their heads, the front of each
   buffer. *)
let batch_size = 4096

let merge_batched
  (type a)
  (inputs : a Pipe.Reader.t array)
  ~(set_head : int -> a -> unit)
  ~(less : a Queue.t array -> int -> int -> bool)
  =
  let n = Array.length inputs in
  let buffers = Array.init n ~f:(fun _ -> Queue.create ()) in
  let heap = Index_heap.create ~capacity:n ~less:(less buffers) in
  let take i =
    let q = buffers.(i) in
    if Queue.is_empty q
    then false
    else (
      set_head i (Queue.peek_exn q);
      Index_heap.add heap i;
      true)
  in
  let refill i =
    match%map Pipe.read' inputs.(i) ~max_queue_length:batch_size with
    | `Eof -> ()
    | `Ok q ->
      buffers.(i) <- q;
      ignore (take i : bool)
  in
  let output =
    Pipe.create_reader ~close_on_exception:true (fun w ->
      let%bind () = Deferred.List.iter ~how:`Parallel (List.init n ~f:Fn.id) ~f:refill in
      let rec loop () =
        if Pipe.is_closed w || Index_heap.is_empty heap
        then return ()
        else (
          let out = Queue.create () in
          let rec drain () =
            if Index_heap.is_empty heap
            then None
            else (
              let i = Index_heap.pop_exn heap in
              Queue.enqueue out (Queue.dequeue_exn buffers.(i));
              if take i then drain () else Some i)
          in
          let dry = drain () in
          let%bind () =
            if Pipe.is_closed w then return () else Pipe.transfer_in w ~from:out
          in
          match dry with
          | None -> return ()
          | Some i ->
            let%bind () = refill i in
            loop ())
      in
      loop ())
  in
  upon (Pipe.closed output) (fun () -> Array.iter inputs ~f:Pipe.close_read);
  output
;;

let sorted inputs ~compare =
  merge_batched
    (Array.of_list inputs)
    ~set_head:(fun _ _ -> ())
    ~less:(fun buffers i j ->
      match compare (Queue.peek_exn buffers.(i)) (Queue.peek_exn buffers.(j)) with
      | 0 -> i < j
      | c -> c < 0)
;;

let sorted_by_key inputs ~key =
  let inputs = Array.of_list inputs in
  let keys = Array.create ~len:(Array.length inputs) 0 in
  merge_batched
    inputs
    ~set_head:(fun i v -> keys.(i) <- key v)
    ~less:(fun _ i j ->
      let a = keys.(i) in
      let b = keys.(j) in
      a < b || (a = b && i < j))
;;
