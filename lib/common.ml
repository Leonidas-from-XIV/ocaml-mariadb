module B = Ffi_bindings.Bindings(Ffi_generated)
module T = Ffi_bindings.Types(Ffi_generated_types)

type mode = [`Blocking | `Nonblocking]
type state = [`Initialized | `Connected | `Tx]

type ('m, 's) t = B.Types.mysql
  constraint 'm = [< mode]
  constraint 's = [< state]

type ('m, 's) mariadb = ('m, 's) t

type flag

type server_option =
  | Multi_statements of bool

module Error = struct
  type t = int * string

  let create mariadb =
    (B.mysql_errno mariadb, B.mysql_error mariadb)

  let errno = fst
  let message = snd
  let make errno msg = (errno, msg)
end

module Bind = struct
  open Ctypes

  type t =
    { n : int
    ; bind : T.Bind.t ptr
    ; length : Unsigned.ulong ptr
    ; is_null : char ptr
    ; is_unsigned : char
    }

  type buffer_type =
    [ `Null
    | `Tiny
    | `Year
    | `Short
    | `Int24
    | `Long
    | `Float
    | `Long_long
    | `Double
    | `Decimal
    | `New_decimal
    | `String
    | `Var_string
    | `Tiny_blob
    | `Blob
    | `Medium_blob
    | `Long_blob
    | `Bit
    | `Time
    | `Date
    | `Datetime
    | `Timestamp
    ]

  let buffer_type_of_int i =
    let open T.Type in
    if i = null              then `Null
    else if i = tiny         then `Tiny
    else if i = year         then `Year
    else if i = short        then `Short
    else if i = int24        then `Int24
    else if i = long         then `Long
    else if i = float        then `Float
    else if i = long_long    then `Long_long
    else if i = double       then `Double
    else if i = decimal      then `Decimal
    else if i = new_decimal  then `New_decimal
    else if i = string       then `String
    else if i = var_string   then `Var_string
    else if i = tiny_blob    then `Tiny_blob
    else if i = blob         then `Blob
    else if i = medium_blob  then `Medium_blob
    else if i = long_blob    then `Long_blob
    else if i = bit          then `Bit
    else if i = time         then `Time
    else if i = date         then `Date
    else if i = datetime     then `Datetime
    else if i = timestamp    then `Timestamp
    else invalid_arg @@ "unknown buffer type " ^ (string_of_int i)

  let t = '\001'
  let f = '\000'

  let alloc n =
    { n
    ; bind = allocate_n T.Bind.t ~count:n
    ; length = allocate_n ulong ~count:n
    ; is_null = allocate_n char ~count:n
    ; is_unsigned = f
    }

  let bind b ~buffer ~size ~mysql_type ~unsigned ~at =
    assert (at >= 0 && at < b.n);
    let size = Unsigned.ULong.of_int size in
    let bp = b.bind +@ at in
    let lp = b.length +@ at in
    lp <-@ size;
    setf (!@bp) T.Bind.length lp;
    setf (!@bp) T.Bind.is_unsigned unsigned;
    setf (!@bp) T.Bind.buffer_type mysql_type;
    setf (!@bp) T.Bind.buffer_length size;
    setf (!@bp) T.Bind.buffer buffer

  let tiny ?(unsigned = false) b param ~at =
    let p = allocate char (char_of_int param) in
    bind b
      ~buffer:(coerce (ptr char) (ptr void) p)
      ~size:(sizeof int)
      ~mysql_type:T.Type.tiny
      ~unsigned:(if unsigned then t else f)
      ~at

  let short ?(unsigned = false) b param ~at =
    let p = allocate short param in
    bind b
      ~buffer:(coerce (ptr short) (ptr void) p)
      ~size:(sizeof int)
      ~mysql_type:T.Type.short
      ~unsigned:(if unsigned then t else f)
      ~at

  let int ?(unsigned = false) b param ~at =
    let p = allocate int param in
    bind b
      ~buffer:(coerce (ptr int) (ptr void) p)
      ~size:(sizeof int)
      ~mysql_type:T.Type.long_long
      ~unsigned:(if unsigned then t else f)
      ~at

  let float b param ~at =
    let p = allocate float param in
    bind b
      ~buffer:(coerce (ptr float) (ptr void) p)
      ~size:(sizeof float)
      ~mysql_type:T.Type.float
      ~unsigned:f
      ~at

  let double b param ~at =
    let p = allocate double param in
    bind b
      ~buffer:(coerce (ptr double) (ptr void) p)
      ~size:(sizeof double)
      ~mysql_type:T.Type.double
      ~unsigned:f
      ~at

  let string b param ~at =
    let len = String.length param in
    let p = allocate_n char ~count:len in
    String.iteri (fun i c -> (p +@ i) <-@ c) param;
    bind b
      ~buffer:(coerce (ptr char) (ptr void) p)
      ~size:len
      ~mysql_type:T.Type.string
      ~unsigned:f
      ~at

  let blob b param ~at =
    let len = Bytes.length param in
    let p = allocate_n char ~count:len in
    String.iteri (fun i c -> (p +@ i) <-@ c) param;
    bind b
      ~buffer:(coerce (ptr char) (ptr void) p)
      ~size:len
      ~mysql_type:T.Type.blob
      ~unsigned:f
      ~at
end

module Res = struct
  type u =
    { mariadb : B.Types.mysql
    ; stmt    : B.Types.stmt
    ; result  : Bind.t
    ; raw     : B.Types.res
    }
  type 'm t = u constraint 'm = [< mode]

  type time =
    { year : int
    ; month : int
    ; day : int
    ; hour : int
    ; minute : int
    ; second : int
    }

  type value =
    [ `Int of int
    | `Float of float
    | `String of string
    | `Bytes of bytes
    | `Time of time
    | `Null
    ]

  let create mariadb stmt result raw =
    { mariadb; stmt; result; raw }

  let num_rows res =
    B.mysql_stmt_num_rows res.stmt

  let affected_rows res =
    B.mysql_stmt_affected_rows res.stmt

  let fetch_field res i =
    let open Ctypes in
    coerce (ptr void) (ptr T.Field.t) (B.mysql_fetch_field_direct res.raw i)

  let free res =
    B.mysql_free_result res.raw
end

let stmt_init mariadb =
  match B.mysql_stmt_init mariadb with
  | Some stmt ->
      B.mysql_stmt_attr_set_bool stmt T.Stmt_attr.update_max_length true;
      Some stmt
  | None ->
      None

module Stmt = struct
  type state = [`Prepared | `Bound | `Executed | `Stored | `Fetch]

  type u =
    { raw : B.Types.stmt
    ; mariadb : B.Types.mysql
    ; res : B.Types.res
    ; num_params : int
    ; params : Bind.t
    ; result : Bind.t
    }
  type ('m, 's) t = u
    constraint 'm = [< mode]
    constraint 's = [< state]

  type cursor_type
    = No_cursor
    | Read_only

  type attr
    = Update_max_length of bool
    | Cursor_type of cursor_type
    | Prefetch_rows of int

  type param =
    [ `Tiny of int
    | `Short of int
    | `Int of int
    | `Float of float
    | `Double of float
    | `String of string
    | `Blob of bytes
    ]

  module Error = struct
    type ('m, 's) stmt = ('m, 's) t
    type t = int * string

    let create stmt =
      (B.mysql_stmt_errno stmt.raw, B.mysql_error stmt.raw)

    let errno = fst
    let message = snd

    let make errno msg = (errno, msg)
  end

  type 'a result = [`Ok of 'a | `Error of Error.t]

  let fetch_field res i =
    let open Ctypes in
    coerce (ptr void) (ptr T.Field.t) (B.mysql_fetch_field_direct res i)

  let alloc_result res =
    let n = B.mysql_num_fields res in
    let r = Bind.alloc n in
    for i = 0 to n - 1 do
      let open Ctypes in
      let bp = r.Bind.bind +@ i in
      let fp = fetch_field res i in
      let flags = Unsigned.UInt.to_int @@ getf (!@fp) T.Field.flags in
      let is_unsigned =
        if flags land T.Field_flags.unsigned <> 0 then '\001'
        else '\001' in
      setf (!@bp) T.Bind.buffer_type (getf (!@fp) T.Field.type_);
      setf (!@bp) T.Bind.length (r.Bind.length +@ i);
      setf (!@bp) T.Bind.is_null (r.Bind.is_null +@ i);
      setf (!@bp) T.Bind.is_unsigned is_unsigned
    done;
    r

  let init mariadb raw =
    let n = B.mysql_stmt_param_count raw in
    match B.mysql_stmt_result_metadata raw with
    | Some res ->
        Some
          { raw
          ; mariadb
          ; res
          ; num_params = n
          ; params = Bind.alloc n
          ; result = alloc_result res
          }
    | None ->
        None

  let bind_params stmt params =
    match Array.length params with
    | 0 -> `Ok stmt
    | n ->
        let b = Bind.alloc n in
        Array.iteri
          (fun at arg ->
            match arg with
            | `Tiny i -> Bind.tiny b i ~at
            | `Short i -> Bind.short b i ~at
            | `Int i -> Bind.int b i ~at
            | `Float x -> Bind.float b x ~at
            | `Double x -> Bind.double b x ~at
            | `String s -> Bind.string b s ~at
            | `Blob s -> Bind.blob b s ~at)
          params;
        if B.mysql_stmt_bind_param stmt.raw b.Bind.bind then
          `Ok stmt
        else
          `Error (Error.create stmt)

  let malloc n =
    let open Ctypes in
    let p = allocate_n char ~count:n in
    coerce (ptr char) (ptr void) p

  let buffer_size typ =
    let open T.Type in
    match Bind.buffer_type_of_int typ with
    | `Null -> 0
    | `Tiny | `Year -> 1
    | `Short -> 2
    | `Int24 | `Long | `Float -> 4
    | `Long_long | `Double -> 8
    | `Decimal | `New_decimal | `String | `Var_string
    | `Tiny_blob | `Blob | `Medium_blob | `Long_blob | `Bit -> -1
    | `Time | `Date | `Datetime | `Timestamp -> Ctypes.sizeof T.Time.t

  let alloc_buffer bp fp typ =
    let open Ctypes in
    let to_ulong = Unsigned.ULong.of_int in
    let of_ulong = Unsigned.ULong.to_int in
    let size =
      match buffer_size typ with
      | -1 -> of_ulong (getf (!@fp) T.Field.max_length)
      | n -> n in
    setf (!@bp) T.Bind.buffer_length (to_ulong size);
    setf (!@bp) T.Bind.buffer (malloc size)

  let bind_result stmt =
    let n = stmt.result.Bind.n in
    let open Ctypes in
    for i = 0 to n - 1 do
      let bp = stmt.result.Bind.bind +@ i in
      let fp = fetch_field stmt.res i in
      let typ = getf (!@fp) T.Field.type_ in
      alloc_buffer bp fp typ
    done;
    if B.mysql_stmt_bind_result stmt.raw stmt.result.Bind.bind then
      `Ok (Res.create stmt.mariadb stmt.raw stmt.result stmt.res)
    else
      `Error (Error.create stmt)
end
