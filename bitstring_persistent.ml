(* Bitstring persistent patterns.
 * Copyright (C) 2008 Red Hat Inc., Richard W.M. Jones
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version,
 * with the OCaml linking exception described in COPYING.LIB.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *
 * $Id: bitstring_persistent.ml 151 2008-08-26 08:21:43Z richard.wm.jones $
 *)

open Printf

open Longident
open Asttypes
open Parsetree
open Ast_helper

type patt = Parsetree.pattern
type expr = Parsetree.expression
type loc_t = Location.t

(* Field.  In bitmatch (patterns) the type is [patt field].  In
 * BITSTRING (constructor) the type is [expr field].
 *)
type 'a field = {
  field : 'a;                           (* field ('a is either patt or expr) *)
  flen : expr;                          (* length in bits, may be non-const *)
  endian : endian_expr;                 (* endianness *)
  signed : bool;                        (* true if signed, false if unsigned *)
  t : field_type;                       (* type *)
  loc : Location.t;                     (* location in source code *)
  offset : expr option;                 (* offset expression *)
  check : expr option;                  (* check expression [patterns only] *)
  bind : expr option;                   (* bind expression [patterns only] *)
  save_offset_to : patt option;         (* save_offset_to [patterns only] *)
}
and field_type = Int | String | Bitstring (* field type *)
and endian_expr =
  | ConstantEndian of Bitstring.endian  (* a constant little/big/nativeendian *)
  | EndianExpr of expr                  (* an endian expression *)

type pattern = patt field list

type constructor = expr field list

type named = string * alt
and alt =
  | Pattern of pattern
  | Constructor of constructor

(* Work out if an expression is an integer constant.
 *
 * Returns [Some i] if so (where i is the integer value), else [None].
 *
 * Fairly simplistic algorithm: we can only detect simple constant
 * expressions such as [k], [k+c], [k-c] etc.
 *)
let rec expr_is_constant e =
  match e.pexp_desc with
  | Pexp_constant (Const_int i) ->      (* Literal integer constant. *)
    Some i
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "+" } }, [_, a; _, b]) -> (* Addition of constants. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a+b)
     | _ -> None)
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "-" } }, [_, a; _, b]) -> (* Subtraction. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a-b)
     | _ -> None)
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "*" } }, [_, a; _, b]) -> (* Multiplication. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a*b)
     | _ -> None)
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "/" } }, [_, a; _, b]) -> (* Division. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a/b)
     | _ -> None)
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "lsl" } }, [_, a; _, b]) -> (* Shift left. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a lsl b)
     | _ -> None)
  | Pexp_apply
      ({ pexp_desc = Pexp_ident { txt = Lident "lsr" } }, [_, a; _, b]) -> (* Shift right. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a lsr b)
     | _ -> None)
  | _ -> None                           (* Anything else is not constant. *)

let string_of_field_type = function
  | Int -> "int"
  | String -> "string"
  | Bitstring -> "bitstring"

let patt_printer = function
  | { ppat_desc = Ppat_var { txt = id } } -> id
  | { ppat_desc = Ppat_any } -> "_"
  | _ -> "[pattern]"

let rec expr_printer = function
  | { pexp_desc = Pexp_ident { txt = Lident id } } -> id
  | { pexp_desc = Pexp_constant (Const_int i) } -> string_of_int i
  | { pexp_desc = Pexp_apply ({ pexp_desc = Pexp_ident { txt = Lident op } }, [(_, a); (_, b)]) } ->
    sprintf "%s %s %s" op (expr_printer a) (expr_printer b)
  | _ -> "[expr]"

let _string_of_field { flen = flen;
                       endian = endian; signed = signed; t = t;
                       loc = loc;
                       offset = offset; check = check; bind = bind;
                       save_offset_to = save_offset_to } =
  let flen = expr_printer flen in
  let endian =
    match endian with
    | ConstantEndian endian -> Bitstring.string_of_endian endian
    | EndianExpr expr -> sprintf "endian(%s)" (expr_printer expr) in
  let signed = if signed then "signed" else "unsigned" in
  let t = string_of_field_type t in

  let offset =
    match offset with
    | None -> ""
    | Some expr -> sprintf ", offset(%s)" (expr_printer expr) in

  let check =
    match check with
    | None -> ""
    | Some expr -> sprintf ", check(%s)" (expr_printer expr) in

  let bind =
    match bind with
    | None -> ""
    | Some expr -> sprintf ", bind(%s)" (expr_printer expr) in

  let save_offset_to =
    match save_offset_to with
    | None -> ""
    | Some patt ->
        match patt with
        | { ppat_desc = Ppat_var { txt = id } } -> sprintf ", save_offset_to(%s)" id
        | _ -> sprintf ", save_offset_to([patt])" in

  let loc_fname = loc.Location.loc_start.Lexing.pos_fname in
  let loc_line = loc.Location.loc_start.Lexing.pos_lnum in
  let loc_char = loc.Location.loc_start.Lexing.pos_cnum - loc.Location.loc_start.Lexing.pos_bol in

  sprintf "%s : %s, %s, %s%s%s%s%s (* %S:%d %d *)"
    flen t endian signed offset check bind save_offset_to
    loc_fname loc_line loc_char

let rec string_of_pattern_field ({ field = patt } as field) =
  sprintf "%s : %s" (patt_printer patt) (_string_of_field field)

and string_of_constructor_field ({ field = expr } as field) =
  sprintf "%s : %s" (expr_printer expr) (_string_of_field field)

let string_of_pattern pattern =
  "{ " ^
    String.concat ";\n  " (List.map string_of_pattern_field pattern) ^
    " }\n"

let string_of_constructor constructor =
  "{ " ^
    String.concat ";\n  " (List.map string_of_constructor_field constructor) ^
    " }\n"

let named_to_channel chan n = Marshal.to_channel chan n []

let named_to_string n = Marshal.to_string n []

let named_to_buffer str ofs len n = Marshal.to_buffer str ofs len n []

let named_from_channel = Marshal.from_channel

let named_from_string = Marshal.from_string

let create_pattern_field loc =
  {
    field = Pat.any ();
    flen = Exp.constant (Const_int 32);
    endian = ConstantEndian Bitstring.BigEndian;
    signed = false;
    t = Int;
    loc = loc;
    offset = None;
    check = None;
    bind = None;
    save_offset_to = None;
  }

let set_lident_patt field id =
  let loc = field.loc in
  { field with field = Pat.var ~loc { txt = id; loc } }
let set_int_patt field i =
  let loc = field.loc in
  { field with field = Pat.constant ~loc (Const_int i) }
let set_string_patt field str =
  let loc = field.loc in
  { field with field = Pat.constant ~loc (Const_string (str, None)) }
let set_unbound_patt field =
  let loc = field.loc in
  { field with field = Pat.any ~loc () }
let set_patt field patt = { field with field = patt }
let set_length_int field flen =
  let loc = field.loc in
  { field with flen = Exp.constant ~loc (Const_int flen) }
let set_length field flen = { field with flen = flen }
let set_endian field endian = { field with endian = ConstantEndian endian }
let set_endian_expr field expr = { field with endian = EndianExpr expr }
let set_signed field signed = { field with signed = signed }
let set_type_int field = { field with t = Int }
let set_type_string field = { field with t = String }
let set_type_bitstring field = { field with t = Bitstring }
let set_location field loc = { field with loc = loc }
let set_offset_int field i =
  let loc = field.loc in
  { field with offset = Some (Exp.constant ~loc (Const_int i)) }
let set_offset field expr = { field with offset = Some expr }
let set_no_offset field = { field with offset = None }
let set_check field expr = { field with check = Some expr }
let set_no_check field = { field with check = None }
let set_bind field expr = { field with bind = Some expr }
let set_no_bind field = { field with bind = None }
let set_save_offset_to field patt = { field with save_offset_to = Some patt }
let set_save_offset_to_lident field id =
  let loc = field.loc in
  { field with save_offset_to = Some (Pat.var ~loc { txt = id; loc }) }
let set_no_save_offset_to field = { field with save_offset_to = None }

let create_constructor_field loc =
  {
    field = Exp.constant (Const_int 0);
    flen = Exp.constant (Const_int 32);
    endian = ConstantEndian Bitstring.BigEndian;
    signed = false;
    t = Int;
    loc = loc;
    offset = None;
    check = None;
    bind = None;
    save_offset_to = None;
  }

let set_lident_expr field id =
  let loc = field.loc in
  { field with field = Exp.ident ~loc { txt = Lident id; loc } }
let set_int_expr field i =
  let loc = field.loc in
  { field with field = Exp.constant ~loc (Const_int i) }
let set_string_expr field str =
  let loc = field.loc in
  { field with field = Exp.constant ~loc (Const_string (str, None)) }
let set_expr field expr =
  let loc = field.loc in
  { field with field = expr }

let get_patt field = field.field
let get_expr field = field.field
let get_length field = field.flen
let get_endian field = field.endian
let get_signed field = field.signed
let get_type field = field.t
let get_location field = field.loc
let get_offset field = field.offset
let get_check field = field.check
let get_bind field = field.bind
let get_save_offset_to field = field.save_offset_to
