open! Core

module Level = struct
  module Stable = struct
    module V1 = struct
      type t =
        { price : Price.Stable.V1.t
        ; size : Size.Stable.V1.t
        }
      [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
    end
  end

  include Stable.V1
end

module Kind = struct
  module Stable = struct
    module V1 = struct
      type t =
        | Snapshot
        | Delta
      [@@deriving bin_io, sexp, compare, equal, quickcheck, enumerate]
    end
  end

  include Stable.V1
end

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; kind : Kind.Stable.V1.t
      ; bids : Level.Stable.V1.t list
      ; asks : Level.Stable.V1.t list
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
  end
end

include Stable.V1
