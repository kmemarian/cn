(* Frontend *)
module CF = Cerb_frontend
module CAE = CF.Cabs_to_ail_effect
module Cn = CF.Cn
module Ctype = CF.Ctype

(* CN specific *)
module BT = BaseTypes
module IT = IndexTerms
module SBT = BaseTypes.Surface
module Mu = Mucore

(* Short forms *)
module Desugar = struct
  let cn_statement = CF.Cabs_to_ail.desugar_cn_statement

  let cn_resource = CF.Cabs_to_ail.desugar_cn_resource

  let cn_assertion = CF.Cabs_to_ail.desugar_cn_assertion

  let cn_expr = CF.Cabs_to_ail.desugar_cn_expr

  let cn_arg = CF.Cabs_to_ail.desugar_cn_arg
end

let get_loc = CF.Annot.get_loc

let get_loc_ = CF.Annot.get_loc_

let fetch_enum d_st loc sym =
  CF.Exception.(
    except_bind (CAE.resolve_enum_constant sym d_st) (fun (expr_, _) ->
      except_return (CF.AilSyntax.AnnotatedExpression ((), [], loc, expr_))))


let fetch_typedef d_st _loc sym =
  CF.Exception.(
    except_bind (CAE.resolve_typedef sym d_st) (fun ((_, _, cty), _) -> except_return cty))


module Translate = struct
  include Compile

  let lift x =
    Result.map_error (fun { loc; msg } -> TypeErrors.{ loc; msg = Compile msg }) x


  let add_datatypes x1 x2 = lift (add_datatypes x1 x2)

  let return_type x1 x2 x3 x4 x5 = lift (return_type x1 x2 x3 x4 x5)

  let ownership x1 x2 = lift (ownership x1 x2)

  let add_user_defined_functions x1 x2 = lift (add_user_defined_functions x1 x2)

  let expr x1 x2 x3 x4 = lift (expr x1 x2 x3 x4)

  let let_resource x1 x2 x3 = lift (let_resource x1 x2 x3)

  let assrt x1 x2 x3 = lift (assrt x1 x2 x3)

  let function_ x1 x2 = lift (function_ x1 x2)

  let lemma x1 x2 = lift (lemma x1 x2)

  let predicate x1 x2 = lift (predicate x1 x2)

  let statement x1 x2 x3 x4 = lift (statement x1 x2 x3 x4)

  let expr_ghost x1 x2 x3 x4 = lift (expr_ghost x1 x2 x3 x4)
end

module Parse = struct
  include Parse

  let lift x =
    Result.map_error (fun { loc; msg } -> TypeErrors.{ loc; msg = Parse msg }) x


  let function_spec attrs = lift (function_spec attrs)

  let loop_spec attrs = lift (loop_spec attrs)

  let cn_statements annots = lift (cn_statements annots)

  let cn_ghost_args annots = lift (cn_ghost_args annots)
end

open CF.Core
open Pp

open Effectful.Make (Or_TypeError)

let fail = Or_TypeError.fail

let do_ail_desugar_op desugar_state f =
  match f desugar_state with
  | CF.Exception.Result (x, st2) -> return (x, st2)
  | CF.Exception.Exception (loc, msg) ->
    fail { loc; msg = Generic !^(CF.Pp_errors.short_message msg) [@alert "-deprecated"] }


let do_ail_desugar_rdonly desugar_state f =
  let@ x, _ = do_ail_desugar_op desugar_state f in
  return x


let register_new_cn_local id d_st =
  do_ail_desugar_op d_st (CF.Cabs_to_ail.register_additional_cn_var id)


(* This rewrite should happen after some partial evaluation and rewrites that
   remove expressions passing ctypes and function pointers as values. The
   embedding into mucore then is partial in those places. Based on
   http://matt.might.net/articles/a-normalization/ *)

exception ConversionFailed

let assert_error loc msg =
  error loc msg [];
  if !Cerb_debug.debug_level > 0 then
    assert false
  else
    raise ConversionFailed


let convert_ct loc ct = Sctypes.of_ctype_unsafe loc ct

let ensure_pexpr_ctype loc err pe : Mu.act =
  match pe with
  | Pexpr (annot, _bty, PEval (Vctype ct)) ->
    { loc; annot; (* type_annot = bty; *) ct = convert_ct loc ct }
  | _ -> assert_error loc (err ^^ colon ^^^ CF.Pp_core.Basic.pp_pexpr pe)


let rec core_to__pattern ~inherit_loc loc (Pattern (annots, pat_)) =
  let loc = (if inherit_loc then Locations.update loc else Fun.id) (get_loc_ annots) in
  let wrap pat_ = Mu.Pattern (loc, annots, (), pat_) in
  match pat_ with
  | CaseBase (msym, cbt1) -> wrap (CaseBase (msym, cbt1))
  | CaseCtor (ctor, pats) ->
    let pats = Lem_pervasives.map (core_to__pattern ~inherit_loc loc) pats in
    (match ctor with
     | Cnil cbt1 -> wrap (CaseCtor (Cnil cbt1, pats))
     | Ccons -> wrap (CaseCtor (Ccons, pats))
     | Ctuple -> wrap (CaseCtor (Ctuple, pats))
     | Carray -> wrap (CaseCtor (Carray, pats))
     | Cspecified -> List.hd pats
     | _ -> assert_error loc !^"core_to_mucore: unsupported pattern")


let rec n_ov loc ov =
  let ov =
    match ov with
    | OVinteger iv -> Mu.OVinteger iv
    | OVfloating fv -> OVfloating fv
    | OVpointer pv -> OVpointer pv
    | OVarray is -> OVarray (List.map (n_lv loc) is)
    | OVstruct (sym1, is) ->
      OVstruct (sym1, List.map (fun (id, ct, mv) -> (id, convert_ct loc ct, mv)) is)
    | OVunion (sym1, id1, mv) -> OVunion (sym1, id1, mv)
  in
  Mu.OV ((), ov)


and n_lv loc v =
  match v with
  | LVspecified ov -> n_ov loc ov
  | LVunspecified _ct1 -> assert_error loc !^"core_anormalisation: LVunspecified"


and n_val loc v =
  let v =
    match v with
    | Vobject ov -> Mu.Vobject (n_ov loc ov)
    | Vloaded lv -> Vobject (n_lv loc lv)
    | Vunit -> Vunit
    | Vtrue -> Vtrue
    | Vfalse -> Vfalse
    | Vctype ct -> Vctype ct
    | Vlist (cbt, vs) -> Vlist (cbt, List.map (n_val loc) vs)
    | Vtuple vs -> Vtuple (List.map (n_val loc) vs)
  in
  V ((), v)


let function_ids =
  [ ("params_length", Mu.F_params_length);
    ("params_nth", F_params_nth);
    ("ctype_width", F_ctype_width)
  ]


let ity_act loc ity =
  Mu.
    { loc;
      annot = [];
      (* type_annot = (); *)
      ct = Sctypes.Integer ity
    }


let rec n_pexpr ~inherit_loc loc (Pexpr (annots, bty, pe)) : unit Mucore.pexpr =
  let loc = (if inherit_loc then Locations.update loc else Fun.id) (get_loc_ annots) in
  let n_pexpr = n_pexpr ~inherit_loc in
  let annotate pe = Mu.Pexpr (loc, annots, bty, pe) in
  match pe with
  | PEsym sym1 -> annotate (PEsym sym1)
  | PEimpl _i -> assert_error loc !^"PEimpl not inlined"
  | PEval v -> annotate (PEval (n_val loc v))
  | PEconstrained l ->
    let l = List.map (fun (c, e) -> (c, n_pexpr loc e)) l in
    annotate (PEconstrained l)
  | PEundef (l, u) -> annotate (PEundef (l, u))
  | PEerror (err, e') -> annotate (PEerror (err, n_pexpr loc e'))
  | PEctor (ctor, args) ->
    let argnum_err () =
      assert_error
        loc
        (item
           "PEctor wrong number of arguments"
           (CF.Pp_core.Basic.pp_pexpr (Pexpr (annots, bty, pe))))
    in
    (match (ctor, args) with
     | CivCOMPL, [ ct; arg1 ] ->
       let ct =
         ensure_pexpr_ctype loc !^"CivCOMPL: first argument not a constant ctype" ct
       in
       let arg1 = n_pexpr loc arg1 in
       annotate (PEwrapI (ct, annotate (PEbitwise_unop (BW_COMPL, arg1))))
     | CivCOMPL, _ -> argnum_err ()
     | CivAND, [ ct; arg1; arg2 ] ->
       let ct =
         ensure_pexpr_ctype loc !^"CivAND: first argument not a constant ctype" ct
       in
       let arg1 = n_pexpr loc arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEwrapI (ct, annotate (PEbitwise_binop (BW_AND, arg1, arg2))))
     | CivAND, _ -> argnum_err ()
     | CivOR, [ ct; arg1; arg2 ] ->
       let ct =
         ensure_pexpr_ctype loc !^"CivOR: first argument not a constant ctype" ct
       in
       let arg1 = n_pexpr loc arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEwrapI (ct, annotate (PEbitwise_binop (BW_OR, arg1, arg2))))
     | CivOR, _ -> argnum_err ()
     | CivXOR, [ ct; arg1; arg2 ] ->
       let ct =
         ensure_pexpr_ctype loc !^"CivXOR: first argument not a constant ctype" ct
       in
       let arg1 = n_pexpr loc arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEwrapI (ct, annotate (PEbitwise_binop (BW_XOR, arg1, arg2))))
     | CivXOR, _ -> argnum_err ()
     | Cfvfromint, [ arg1 ] ->
       let arg1 = n_pexpr loc arg1 in
       annotate (Cfvfromint arg1)
     | Cfvfromint, _ -> argnum_err ()
     | Civfromfloat, [ ct; arg1 ] ->
       let ct =
         ensure_pexpr_ctype loc !^"Civfromfloat: first argument not a constant ctype" ct
       in
       let arg1 = n_pexpr loc arg1 in
       annotate (Civfromfloat (ct, arg1))
     | Civfromfloat, _ -> argnum_err ()
     | Cnil bt1, _ -> annotate (PEctor (Cnil bt1, List.map (n_pexpr loc) args))
     | Ccons, _ -> annotate (PEctor (Ccons, List.map (n_pexpr loc) args))
     | Ctuple, _ -> annotate (PEctor (Ctuple, List.map (n_pexpr loc) args))
     | Carray, _ -> annotate (PEctor (Carray, List.map (n_pexpr loc) args))
     | Cspecified, _ -> n_pexpr loc (List.hd args)
     | Civsizeof, [ ct_expr ] ->
       annotate (PEapply_fun (F_size_of, [ n_pexpr loc ct_expr ]))
     | Civsizeof, _ -> argnum_err ()
     | Civalignof, [ ct_expr ] ->
       annotate (PEapply_fun (F_align_of, [ n_pexpr loc ct_expr ]))
     | Civalignof, _ -> argnum_err ()
     | Civmax, [ ct_expr ] -> annotate (PEapply_fun (F_max_int, [ n_pexpr loc ct_expr ]))
     | Civmax, _ -> argnum_err ()
     | Civmin, [ ct_expr ] -> annotate (PEapply_fun (F_min_int, [ n_pexpr loc ct_expr ]))
     | Civmin, _ -> argnum_err ()
     | _ ->
       assert_error
         loc
         (item
            "core_to_mucore: unsupported ctor application"
            (CF.Pp_core.Basic.pp_pexpr (Pexpr (annots, bty, pe)))))
  | PEcase (_e', _pats_pes) -> assert_error loc !^"PEcase"
  | PEarray_shift (e', ct, e'') ->
    let e' = n_pexpr loc e' in
    let e'' = n_pexpr loc e'' in
    annotate (PEarray_shift (e', convert_ct loc ct, e''))
  | PEmember_shift (e', sym1, id1) ->
    let e' = n_pexpr loc e' in
    annotate (PEmember_shift (e', sym1, id1))
  | PEmemop (_mop, _pes) ->
    (* FIXME(CHERI merge) *)
    (* this construct is currently only used by the CHERI switch *)
    assert_error loc !^"PEmemop (CHERI only)"
  | PEnot e' ->
    let e' = n_pexpr loc e' in
    annotate (PEnot e')
  | PEop (binop1, e', e'') ->
    let e' = n_pexpr loc e' in
    let e'' = n_pexpr loc e'' in
    annotate (PEop (binop1, e', e''))
  | PEstruct (sym1, fields) ->
    let fields = List.map (fun (m, e) -> (m, n_pexpr loc e)) fields in
    annotate (PEstruct (sym1, fields))
  | PEunion (sym1, id1, e') ->
    let e' = n_pexpr loc e' in
    annotate (PEunion (sym1, id1, e'))
  | PEcfunction e' ->
    let e' = n_pexpr loc e' in
    annotate (PEcfunction e')
  | PEmemberof (sym1, id1, e') ->
    let e' = n_pexpr loc e' in
    annotate (PEmemberof (sym1, id1, e'))
  | PEconv_int (ity, e') ->
    let e' = n_pexpr loc e' in
    let ity_e =
      annotate (PEval (V ((), Vctype (Sctypes.to_ctype (Sctypes.Integer ity)))))
    in
    annotate (PEconv_int (ity_e, e'))
  | PEwrapI (ity, iop, arg1, arg2) ->
    let act = ity_act loc ity in
    let arg1 = n_pexpr loc arg1 in
    let arg2 = n_pexpr loc arg2 in
    annotate (PEbounded_binop (Bound_Wrap act, iop, arg1, arg2))
  | PEcatch_exceptional_condition (ity, iop, arg1, arg2) ->
    let act = ity_act loc ity in
    let arg1 = n_pexpr loc arg1 in
    let arg2 = n_pexpr loc arg2 in
    annotate (PEbounded_binop (Bound_Except act, iop, arg1, arg2))
  | PEcall (sym1, args) ->
    (match (sym1, args) with
     | Sym (Symbol (_, _, SD_Id "conv_int")), [ arg1; arg2 ] ->
       let arg1 = n_pexpr loc arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEconv_int (arg1, arg2))
     | Sym (Symbol (_, _, SD_Id "conv_loaded_int")), [ arg1; arg2 ] ->
       let arg1 = n_pexpr loc arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEconv_loaded_int (arg1, arg2))
     | Sym (Symbol (_, _, SD_Id "wrapI")), [ arg1; arg2 ] ->
       let ct = ensure_pexpr_ctype loc !^"PEcall(wrapI,_): not a constant ctype" arg1 in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEwrapI (ct, arg2))
     | Sym (Symbol (_, _, SD_Id "catch_exceptional_condition")), [ arg1; arg2 ] ->
       let ct =
         ensure_pexpr_ctype
           loc
           !^"PEcall(catch_exceptional_condition,_): not a constant ctype"
           arg1
       in
       let arg2 = n_pexpr loc arg2 in
       annotate (PEcatch_exceptional_condition (ct, arg2))
     | Sym (Symbol (_, _, SD_Id "is_representable_integer")), [ arg1; arg2 ] ->
       let arg1 = n_pexpr loc arg1 in
       let ct =
         ensure_pexpr_ctype
           loc
           !^"PEcall(is_representable_integer,_): not a constant ctype"
           arg2
       in
       annotate (PEis_representable_integer (arg1, ct))
     | Sym (Symbol (_, _, SD_Id "all_values_representable_in")), [ arg1; arg2 ] ->
       let ct1 =
         ensure_pexpr_ctype
           loc
           !^"PEcall(all_values_representable_in,_): not a constant ctype"
           arg1
       in
       let ct2 =
         ensure_pexpr_ctype
           loc
           !^"PEcall(all_values_representable_in,_): not a constant ctype"
           arg2
       in
       (match (Sctypes.is_integer_type ct1.ct, Sctypes.is_integer_type ct2.ct) with
        | Some ity1, Some ity2 ->
          if Memory.all_values_representable_in (ity1, ity2) then
            annotate (PEval (V ((), Vtrue)))
          else
            annotate (PEval (V ((), Vfalse)))
        | _ ->
          assert_error
            loc
            (!^"all_values_representable_in: not integer types:"
             ^^^ list CF.Pp_core.Basic.pp_pexpr [ arg1; arg2 ]))
     | Sym (Symbol (_, _, SD_Id fun_id)), args ->
       (match List.assoc_opt String.equal fun_id function_ids with
        | Some fun_id ->
          let args = List.map (n_pexpr loc) args in
          annotate (PEapply_fun (fun_id, args))
        | None ->
          assert_error
            loc
            (!^"PEcall (SD_Id) not inlined: "
             ^^^ !^fun_id
             ^^ colon
             ^^^ list CF.Pp_core.Basic.pp_pexpr args))
     | Sym sym, _ -> assert_error loc (!^"PEcall not inlined:" ^^^ Sym.pp sym)
     | Impl impl, args ->
       (match (impl, args) with
        | ( CF.Implementation.SHR_signed_negative,
            [ Pexpr (_, _, PEval (Vctype ct)); arg1; arg2 ] ) ->
          let arg1 = n_pexpr loc arg1 in
          let arg2 = n_pexpr loc arg2 in
          let ity =
            match Sctypes.is_integer_type (convert_ct loc ct) with
            | Some i -> i
            | None -> failwith "Non-integer type in shift"
          in
          let act = ity_act loc ity in
          let op = CF.Core.IOpShr in
          let bound = Mu.Bound_Except act in
          let shift = annotate (PEbounded_binop (bound, op, arg1, arg2)) in
          let impl_ok =
            true
            (* XXX: parameterize *)
          in
          if impl_ok then
            shift
          else
            annotate
              (PEerror
                 ( "Shifting a negative number to the right is implementation-dependant.",
                   shift ))
          (* XXX: Make a type for reporting implementation defined behavior? *)
        | _ ->
          assert_error
            loc
            (!^"PEcall to impl not inlined:"
             ^^^ !^(CF.Implementation.string_of_implementation_constant impl))))
  | PElet (pat, e', e'') ->
    (match (pat, e') with
     | Pattern (_annots, CaseBase (Some sym, _)), Pexpr (annots2, _, PEsym sym2)
     | ( Pattern (_annots, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym, _)) ])),
         Pexpr (annots2, _, PEsym sym2) ) ->
       let e'' = CF.Core_peval.subst_sym_pexpr2 sym (get_loc annots2, `SYM sym2) e'' in
       n_pexpr loc e''
     | ( Pattern
           ( _annots,
             CaseCtor
               ( Ctuple,
                 [ Pattern (_, CaseBase (Some sym, _));
                   Pattern (_, CaseBase (Some sym', _))
                 ] ) ),
         Pexpr
           ( annots2,
             _,
             PEctor (Ctuple, [ Pexpr (_, _, PEsym sym2); Pexpr (_, _, PEsym sym2') ]) ) )
     | ( Pattern
           ( _annots,
             CaseCtor
               ( Ctuple,
                 [ Pattern
                     (_, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym, _)) ]));
                   Pattern
                     (_, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym', _)) ]))
                 ] ) ),
         Pexpr
           ( annots2,
             _,
             PEctor (Ctuple, [ Pexpr (_, _, PEsym sym2); Pexpr (_, _, PEsym sym2') ]) ) )
     (* pairwise disjoint *)
       when List.length (List.sort_uniq Sym.compare [ sym; sym'; sym2; sym2' ]) = 4 ->
       let e'' = CF.Core_peval.subst_sym_pexpr2 sym (get_loc annots2, `SYM sym2) e'' in
       let e'' = CF.Core_peval.subst_sym_pexpr2 sym' (get_loc annots2, `SYM sym2') e'' in
       n_pexpr loc e''
     | _ ->
       let pat = core_to__pattern ~inherit_loc loc pat in
       let e' = n_pexpr loc e' in
       let e'' = n_pexpr loc e'' in
       annotate (PElet (pat, e', e'')))
  | PEif (e1, e2, e3) ->
    (match (e2, e3) with
     | ( Pexpr (_, _, PEval (Vloaded (LVspecified (OVinteger iv1)))),
         Pexpr (_, _, PEval (Vloaded (LVspecified (OVinteger iv2)))) )
       when Option.equal Z.equal (CF.Mem.eval_integer_value iv1) (Some Z.one)
            && Option.equal Z.equal (CF.Mem.eval_integer_value iv2) (Some Z.zero) ->
       let e1 = n_pexpr loc e1 in
       annotate (PEbool_to_integer e1)
     | ( Pexpr
           (_, _, PEctor (Cspecified, [ Pexpr (_, _, PEval (Vobject (OVinteger iv1))) ])),
         Pexpr
           (_, _, PEctor (Cspecified, [ Pexpr (_, _, PEval (Vobject (OVinteger iv2))) ]))
       )
       when Option.equal Z.equal (CF.Mem.eval_integer_value iv1) (Some Z.one)
            && Option.equal Z.equal (CF.Mem.eval_integer_value iv2) (Some Z.zero) ->
       let e1 = n_pexpr loc e1 in
       annotate (PEbool_to_integer e1)
     (* this should go away *)
     | Pexpr (_, _, PEval Vtrue), Pexpr (_, _, PEval Vfalse) -> n_pexpr loc e1
     | _ ->
       let e1 = n_pexpr loc e1 in
       let e2 = n_pexpr loc e2 in
       let e3 = n_pexpr loc e3 in
       (match e1 with
        | Pexpr (_, _, _, PEval (V (_, Vtrue))) -> e2
        | Pexpr (_, _, _, PEval (V (_, Vfalse))) -> e3
        | _ -> annotate (PEif (e1, e2, e3))))
  | PEis_scalar _e' -> assert_error loc !^"core_anormalisation: PEis_scalar"
  | PEis_integer _e' -> assert_error loc !^"core_anormalisation: PEis_integer"
  | PEis_signed _e' -> assert_error loc !^"core_anormalisation: PEis_signed"
  | PEis_unsigned _e' -> assert_error loc !^"core_anormalisation: PEis_unsigned"
  | PEbmc_assume _e' -> assert_error loc !^"core_anormalisation: PEbmc_assume"
  | PEare_compatible (e1, e2) ->
    let e1 = n_pexpr loc e1 in
    let e2 = n_pexpr loc e2 in
    annotate (PEapply_fun (F_are_compatible, [ e1; e2 ]))


let n_kill_kind loc = function
  | Dynamic -> Mu.Dynamic
  | Static0 ct -> Static (convert_ct loc ct)


let n_action ~inherit_loc loc action =
  let (Action (loc', _, a1)) = action in
  let loc = (if inherit_loc then Locations.update loc else Fun.id) loc' in
  let n_pexpr = n_pexpr ~inherit_loc in
  let wrap a1 = Mu.Action (loc, a1) in
  match a1 with
  | Create (e1, e2, sym1) ->
    let ctype1 = ensure_pexpr_ctype loc !^"Create: not a constant ctype" e2 in
    let e1 = n_pexpr loc e1 in
    wrap (Create (e1, ctype1, sym1))
  | CreateReadOnly (e1, e2, e3, sym1) ->
    let ctype = ensure_pexpr_ctype loc !^"CreateReadOnly: not a constant ctype" e2 in
    let e1 = n_pexpr loc e1 in
    let e3 = n_pexpr loc e3 in
    wrap (CreateReadOnly (e1, ctype, e3, sym1))
  | Alloc0 (e1, e2, sym1) ->
    let e1 = n_pexpr loc e1 in
    let e2 = n_pexpr loc e2 in
    wrap (Alloc (e1, e2, sym1))
  | Kill (kind, e1) ->
    let e1 = n_pexpr loc e1 in
    wrap (Kill (n_kill_kind loc kind, e1))
  | Store0 (b, e1, e2, e3, mo1) ->
    let ctype1 = ensure_pexpr_ctype loc !^"Store: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    wrap (Store (b, ctype1, e2, e3, mo1))
  | Load0 (e1, e2, mo1) ->
    let ctype1 = ensure_pexpr_ctype loc !^"Load: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    wrap (Load (ctype1, e2, mo1))
  | SeqRMW (_b, _e1, _e2, _sym, _e3) -> assert_error loc !^"TODO: SeqRMW"
  (* let ctype1 = (ensure_pexpr_ctype loc !^"SeqRMW: not a constant ctype" e1) in
     n_pexpr_in_expr_name e2 (fun e2 -> n_pexpr_in_expr_name e3 (fun e3 -> k (wrap
     (SeqRMW(ctype1, e2, sym, e3))))) *)
  | RMW0 (e1, e2, e3, e4, mo1, mo2) ->
    let ctype1 = ensure_pexpr_ctype loc !^"RMW: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    let e4 = n_pexpr loc e4 in
    wrap (RMW (ctype1, e2, e3, e4, mo1, mo2))
  | Fence0 mo1 -> wrap (Fence mo1)
  | CompareExchangeStrong (e1, e2, e3, e4, mo1, mo2) ->
    let ctype1 =
      ensure_pexpr_ctype loc !^"CompareExchangeStrong: not a constant ctype" e1
    in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    let e4 = n_pexpr loc e4 in
    wrap (CompareExchangeStrong (ctype1, e2, e3, e4, mo1, mo2))
  | CompareExchangeWeak (e1, e2, e3, e4, mo1, mo2) ->
    let ctype1 =
      ensure_pexpr_ctype loc !^"CompareExchangeWeak: not a constant ctype" e1
    in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    let e4 = n_pexpr loc e4 in
    wrap (CompareExchangeWeak (ctype1, e2, e3, e4, mo1, mo2))
  | LinuxFence lmo -> wrap (LinuxFence lmo)
  | LinuxLoad (e1, e2, lmo) ->
    let ctype1 = ensure_pexpr_ctype loc !^"LinuxLoad: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    wrap (LinuxLoad (ctype1, e2, lmo))
  | LinuxStore (e1, e2, e3, lmo) ->
    let ctype1 = ensure_pexpr_ctype loc !^"LinuxStore: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    wrap (LinuxStore (ctype1, e2, e3, lmo))
  | LinuxRMW (e1, e2, e3, lmo) ->
    let ctype1 = ensure_pexpr_ctype loc !^"LinuxRMW: not a constant ctype" e1 in
    let e2 = n_pexpr loc e2 in
    let e3 = n_pexpr loc e3 in
    wrap (LinuxRMW (ctype1, e2, e3, lmo))


let n_paction ~inherit_loc loc (Paction (pol, a)) =
  Mu.Paction (pol, n_action ~inherit_loc loc a)


let show_n_memop =
  CF.Mem_common.(
    instance_Show_Show_Mem_common_generic_memop_dict
      CF.Symbol.instance_Show_Show_Symbol_sym_dict)
    .show_method


let n_memop ~inherit_loc loc memop pexprs =
  let n_pexpr = n_pexpr ~inherit_loc in
  let open CF.Mem_common in
  match (memop, pexprs) with
  | PtrEq, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    Mu.PtrEq (pe1, pe2)
  | PtrNe, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrNe (pe1, pe2)
  | PtrLt, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrLt (pe1, pe2)
  | PtrGt, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrGt (pe1, pe2)
  | PtrLe, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrLe (pe1, pe2)
  | PtrGe, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrGe (pe1, pe2)
  | Ptrdiff, [ ct1; pe1; pe2 ] ->
    let ct1 = ensure_pexpr_ctype loc !^"Ptrdiff: not a constant ctype" ct1 in
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    Ptrdiff (ct1, pe1, pe2)
  | IntFromPtr, [ ct1; ct2; pe ] ->
    let ct1 = ensure_pexpr_ctype loc !^"IntFromPtr: not a constant ctype" ct1 in
    let ct2 = ensure_pexpr_ctype loc !^"IntFromPtr: not a constant ctype" ct2 in
    let pe = n_pexpr loc pe in
    IntFromPtr (ct1, ct2, pe)
  | PtrFromInt, [ ct1; ct2; pe ] ->
    let ct1 = ensure_pexpr_ctype loc !^"PtrFromInt: not a constant ctype" ct1 in
    let ct2 = ensure_pexpr_ctype loc !^"PtrFromInt: not a constant ctype" ct2 in
    let pe = n_pexpr loc pe in
    PtrFromInt (ct1, ct2, pe)
  | PtrValidForDeref, [ ct1; pe ] ->
    let ct1 = ensure_pexpr_ctype loc !^"PtrValidForDeref: not a constant ctype" ct1 in
    let pe = n_pexpr loc pe in
    PtrValidForDeref (ct1, pe)
  | PtrWellAligned, [ ct1; pe ] ->
    let ct1 = ensure_pexpr_ctype loc !^"PtrWellAligned: not a constant ctype" ct1 in
    let pe = n_pexpr loc pe in
    PtrWellAligned (ct1, pe)
  | PtrArrayShift, [ pe1; ct1; pe2 ] ->
    let ct1 = ensure_pexpr_ctype loc !^"PtrArrayShift: not a constant ctype" ct1 in
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    PtrArrayShift (pe1, ct1, pe2)
  | Memcpy, [ pe1; pe2; pe3 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    let pe3 = n_pexpr loc pe3 in
    Memcpy (pe1, pe2, pe3)
  | Memcmp, [ pe1; pe2; pe3 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    let pe3 = n_pexpr loc pe3 in
    Memcmp (pe1, pe2, pe3)
  | Realloc, [ pe1; pe2; pe3 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    let pe3 = n_pexpr loc pe3 in
    Realloc (pe1, pe2, pe3)
  | Va_start, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    Va_start (pe1, pe2)
  | Va_copy, [ pe ] ->
    let pe = n_pexpr loc pe in
    Va_copy pe
  | Va_arg, [ pe; ct1 ] ->
    let ct1 = ensure_pexpr_ctype loc !^"Va_arg: not a constant ctype" ct1 in
    let pe = n_pexpr loc pe in
    Va_arg (pe, ct1)
  | Va_end, [ pe ] ->
    let pe = n_pexpr loc pe in
    Va_end pe
  | Copy_alloc_id, [ pe1; pe2 ] ->
    let pe1 = n_pexpr loc pe1 in
    let pe2 = n_pexpr loc pe2 in
    CopyAllocId (pe1, pe2)
  | PtrMemberShift _, _ -> assert_error loc !^"PtrMemberShift (CHERI only)"
  | memop, pexprs1 ->
    let err =
      !^__LOC__
      ^^ colon
      ^^^ !^(show_n_memop memop)
      ^^^ !^"applied to"
      ^^^ int (List.length pexprs1)
      ^^^ !^"arguments"
    in
    assert_error loc err


let unsupported loc doc = fail { loc; msg = Unsupported (!^"unsupported" ^^^ doc) }

let rec n_expr
          ~inherit_loc
          (loc : Locations.t)
          ((env, old_states), desugaring_things)
          (global_types, visible_objects_env)
          e
  : unit Mucore.expr Or_TypeError.t
  =
  let markers_env, cn_desugaring_state = desugaring_things in
  let (Expr (annots, pe)) = e in
  let loc = (if inherit_loc then Locations.update loc else Fun.id) (get_loc_ annots) in
  let wrap pe = Mu.Expr (loc, annots, (), pe) in
  let wrap_pure pe = wrap (Epure (Pexpr (loc, [], (), pe))) in
  let n_pexpr = n_pexpr ~inherit_loc loc in
  let n_paction = n_paction ~inherit_loc loc in
  let n_memop = n_memop ~inherit_loc loc in
  let n_expr =
    n_expr
      ~inherit_loc
      loc
      ((env, old_states), desugaring_things)
      (global_types, visible_objects_env)
  in
  match pe with
  | Epure pexpr2 -> return (wrap (Epure (n_pexpr pexpr2)))
  | Ememop (memop1, pexprs1) -> return (wrap (Ememop (n_memop memop1 pexprs1)))
  | Eaction paction2 -> return (wrap (Eaction (n_paction paction2)))
  | Ecase (_pexpr, _pats_es) -> assert_error loc !^"Ecase"
  | Elet (pat, e1, e2) ->
    (match (pat, e1) with
     | Pattern (_annots, CaseBase (Some sym, _)), Pexpr (annots2, _, PEsym sym2)
     | ( Pattern (_annots, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym, _)) ])),
         Pexpr (annots2, _, PEsym sym2) ) ->
       let e2 = CF.Core_peval.subst_sym_expr2 sym (get_loc annots2, `SYM sym2) e2 in
       n_expr e2
     | ( Pattern
           ( _annots,
             CaseCtor
               ( Ctuple,
                 [ Pattern (_, CaseBase (Some sym, _));
                   Pattern (_, CaseBase (Some sym', _))
                 ] ) ),
         Pexpr
           ( annots2,
             _,
             PEctor (Ctuple, [ Pexpr (_, _, PEsym sym2); Pexpr (_, _, PEsym sym2') ]) ) )
     | ( Pattern
           ( _annots,
             CaseCtor
               ( Ctuple,
                 [ Pattern
                     (_, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym, _)) ]));
                   Pattern
                     (_, CaseCtor (Cspecified, [ Pattern (_, CaseBase (Some sym', _)) ]))
                 ] ) ),
         Pexpr
           ( annots2,
             _,
             PEctor (Ctuple, [ Pexpr (_, _, PEsym sym2); Pexpr (_, _, PEsym sym2') ]) ) )
     (* pairwise disjoint *)
       when List.length (List.sort_uniq Sym.compare [ sym; sym'; sym2; sym2' ]) = 4 ->
       let e2 = CF.Core_peval.subst_sym_expr2 sym (get_loc annots2, `SYM sym2) e2 in
       let e2 = CF.Core_peval.subst_sym_expr2 sym' (get_loc annots2, `SYM sym2') e2 in
       n_expr e2
     | _ ->
       let e1 = n_pexpr e1 in
       let pat = core_to__pattern ~inherit_loc loc pat in
       let@ e2 = n_expr e2 in
       return (wrap (Elet (pat, e1, e2))))
  | Eif (e1, e2, e3) ->
    (match (e2, e3) with
     | ( Expr (_, Epure (Pexpr (_, _, PEval (Vloaded (LVspecified (OVinteger iv1)))))),
         Expr (_, Epure (Pexpr (_, _, PEval (Vloaded (LVspecified (OVinteger iv2)))))) )
       when Option.equal Z.equal (CF.Mem.eval_integer_value iv1) (Some Z.one)
            && Option.equal Z.equal (CF.Mem.eval_integer_value iv2) (Some Z.zero) ->
       let e1 = n_pexpr e1 in
       return (wrap_pure (PEbool_to_integer e1))
     | ( Expr (_, Epure (Pexpr (_, _, PEval Vtrue))),
         Expr (_, Epure (Pexpr (_, _, PEval Vfalse))) ) ->
       let e1 = n_pexpr e1 in
       return (wrap (Epure e1))
     | _ ->
       let e1 = n_pexpr e1 in
       let@ e2 = n_expr e2 in
       let@ e3 = n_expr e3 in
       return (wrap (Eif (e1, e2, e3))))
  | Eccall (_a, ct1, e2, es) ->
    let ct1 =
      match ct1 with
      | Pexpr (annot, _bty, PEval (Vctype ct1)) ->
        let loc =
          (if inherit_loc then Locations.update loc else Fun.id) (get_loc_ annots)
        in
        Mu.{ loc; annot; (* type_annot = bty; *) ct = convert_ct loc ct1 }
      | _ ->
        assert_error loc !^"core_anormalisation: Eccall with non-ctype first argument"
    in
    let@ e2 =
      let err () = unsupported loc !^"invalid function constant" in
      match e2 with
      | Pexpr (annots, bty, PEval v) ->
        let@ sym =
          match v with
          | Vobject (OVpointer ptrval) | Vloaded (LVspecified (OVpointer ptrval)) ->
            CF.Impl_mem.case_ptrval
              ptrval
              (fun _ct -> err ())
              (function
                | None -> (* FIXME(CHERI merge) *) err () | Some sym -> return sym)
              (fun _prov _ -> err ())
          | _ -> err ()
        in
        return (Mu.Pexpr (loc, annots, bty, PEval (V ((), Vfunction_addr sym))))
      | _ -> return @@ n_pexpr e2
    in
    let es = List.map n_pexpr es in
    let@ parsed_ghosts = Parse.cn_ghost_args annots in
    let@ ghost_args =
      match parsed_ghosts with
      | None -> return None
      | Some (ghost_loc, args) ->
        let marker_id = Option.get (CF.Annot.get_marker annots) in
        let marker_id_object_types =
          Option.get (CF.Annot.get_marker_object_types annots)
        in
        let visible_objects =
          global_types @ Pmap.find marker_id_object_types visible_objects_env
        in
        let get_c_obj sym =
          match List.assoc_opt Sym.equal sym visible_objects with
          | Some obj_ty -> obj_ty
          | None ->
            (* should not occur since Cerberus guarantees every C object in scope has a type *)
            failwith ("use of C obj without known type: " ^ Sym.pp_string sym)
        in
        let@ ghosts =
          ListM.mapM
            (fun parsed_ghost ->
               let@ desugared_ghost =
                 do_ail_desugar_rdonly
                   CAE.
                     { markers_env;
                       inner =
                         { (Pmap.find marker_id markers_env) with
                           cn_state = cn_desugaring_state
                         }
                     }
                   (Desugar.cn_expr parsed_ghost)
               in
               let@ ghost =
                 Translate.expr_ghost get_c_obj old_states env desugared_ghost
               in
               return ghost)
            args
        in
        let ghost_args = List.map (Cnprog.map IT.Surface.proj) ghosts in
        return (Some (ghost_loc, ghost_args))
    in
    return (wrap (Eccall (ct1, e2, es, ghost_args)))
  | Eproc (_a, name, es) ->
    let es = List.map n_pexpr es in
    (match (name, es) with
     | Impl (BuiltinFunction "ctz"), [ arg1 ] ->
       return (wrap_pure (PEbitwise_unop (BW_CTZ, arg1)))
     | Impl (BuiltinFunction "generic_ffs"), [ arg1 ] ->
       return (wrap_pure (PEbitwise_unop (BW_FFS, arg1)))
     | _ -> assert_error loc (item "Eproc" (CF.Pp_core_ast.pp_expr e)))
  | Eunseq es ->
    let@ es = ListM.mapM n_expr es in
    return (wrap (Eunseq es))
  | Ewseq (pat, e1, e2) ->
    let@ e1 = n_expr e1 in
    let pat = core_to__pattern ~inherit_loc loc pat in
    let@ e2 = n_expr e2 in
    return (wrap (Ewseq (pat, e1, e2)))
  | Esseq (pat, e1, e2) ->
    (* let () = debug 10 (lazy (item "core_to_mucore Esseq. e1:"
       (CF.Pp_core_ast.pp_expr e1))) in let () = debug 10 (lazy (item
       "core_to_mucore Esseq. e2:" (CF.Pp_core_ast.pp_expr e2))) in let () = debug
       10 (lazy (item "core_to_mucore Esseq. p:" (CF.Pp_core.Basic.pp_pattern pat)))
       in *)
    let@ e1 =
      match (pat, e1) with
      | ( Pattern ([], CaseBase (None, BTy_unit)),
          Expr ([], Epure (Pexpr ([], (), PEval Vunit))) ) ->
        let@ parsed_stmts = Parse.cn_statements annots in
        (match parsed_stmts with
         | _ :: _ ->
           let marker_id = Option.get (CF.Annot.get_marker annots) in
           let marker_id_object_types =
             Option.get (CF.Annot.get_marker_object_types annots)
           in
           let visible_objects =
             global_types @ Pmap.find marker_id_object_types visible_objects_env
           in
           let get_c_obj sym =
             match List.assoc_opt Sym.equal sym visible_objects with
             | Some obj_ty -> obj_ty
             | None -> failwith ("use of C obj without known type: " ^ Sym.pp_string sym)
             (* should not occur since Cerberus guarantees every C object in scope has a type *)
           in
           let@ desugared_stmts_and_stmts =
             ListM.mapM
               (fun parsed_stmt ->
                  let@ desugared_stmt =
                    do_ail_desugar_rdonly
                      CAE.
                        { markers_env;
                          inner =
                            { (Pmap.find marker_id markers_env) with
                              cn_state = cn_desugaring_state
                            }
                        }
                      (Desugar.cn_statement parsed_stmt)
                  in
                  (* debug 6 (lazy (!^"CN statement before translation")); debug 6 (lazy
                    (pp_doc_tree (CF.Cn_ocaml.PpAil.dtree_of_cn_statement
                    desugared_stmt))); *)
                  let@ stmt =
                    Translate.statement get_c_obj old_states env desugared_stmt
                  in
                  (* debug 6 (lazy (!^"CN statement after translation")); debug 6 (lazy
                    (pp_doc_tree (Cnprog.dtree stmt))); *)
                  return (desugared_stmt, stmt))
               parsed_stmts
           in
           let desugared_stmts, stmts = List.split desugared_stmts_and_stmts in
           return (Mu.Expr (loc, [], (), CN_progs (desugared_stmts, stmts)))
         | [] -> n_expr e1)
      | _, _ -> n_expr e1
    in
    let pat = core_to__pattern ~inherit_loc loc pat in
    let@ e2 = n_expr e2 in
    return (wrap (Esseq (pat, e1, e2)))
  | Ebound e ->
    let@ e = n_expr e in
    return (wrap (Ebound e))
  | End es ->
    let@ es = ListM.mapM n_expr es in
    return (wrap (End es))
  | Esave ((_sym1, _bt1), _syms_typs_pes, _e) ->
    assert_error loc !^"core_anormalisation: Esave"
  | Erun (_a, sym1, pes) ->
    let pes = List.map n_pexpr pes in
    (* TODO: https://github.com/rems-project/cn/issues/123 *)
    return (wrap (Erun (sym1, pes)))
  | Epar _es -> assert_error loc !^"core_anormalisation: Epar"
  | Ewait _tid1 -> assert_error loc !^"core_anormalisation: Ewait"
  | Eannot _ -> assert_error loc !^"core_anormalisation: Eannot"
  | Eexcluded _ -> assert_error loc !^"core_anormalisation: Eexcluded"


module AT = ArgumentTypes
module LAT = LogicalArgumentTypes

let rec lat_of_arguments f_i = function
  | Mu.Define (bound, info, l) -> LAT.Define (bound, info, lat_of_arguments f_i l)
  | Resource (bound, info, l) -> LAT.Resource (bound, info, lat_of_arguments f_i l)
  | Constraint (lc, info, l) -> LAT.Constraint (lc, info, lat_of_arguments f_i l)
  | I i -> LAT.I (f_i i)


let rec at_of_arguments f_i = function
  | Mu.Computational (bound, info, a) ->
    AT.Computational (bound, info, at_of_arguments f_i a)
  | Mu.Ghost (bound, info, a) -> AT.Ghost (bound, info, at_of_arguments f_i a)
  | L l -> AT.L (lat_of_arguments f_i l)


let rec arguments_of_lat f_i = function
  | LAT.Define (def, info, lat) -> Mu.Define (def, info, arguments_of_lat f_i lat)
  | LAT.Resource (bound, info, lat) -> Resource (bound, info, arguments_of_lat f_i lat)
  | LAT.Constraint (c, info, lat) -> Constraint (c, info, arguments_of_lat f_i lat)
  | LAT.I i -> I (f_i i)


let rec arguments_of_at f_i = function
  | AT.Computational (bound, info, at) ->
    Mu.Computational (bound, info, arguments_of_at f_i at)
  | AT.Ghost (bound, info, at) -> Mu.Ghost (bound, info, arguments_of_at f_i at)
  | AT.L lat -> L (arguments_of_lat f_i lat)


(* copying and adjusting variously compile.ml logic *)

let make_largs f_i =
  let rec aux env st = function
    | Cn.CN_cletResource (loc, name, resource) :: conditions ->
      let@ (pt_ret, oa_bt), lcs, pointee_values =
        Translate.let_resource env st (name, resource)
      in
      let env = Translate.add_logical name oa_bt env in
      let st = Translate.C_vars.add_pointee_values pointee_values st in
      let@ lat = aux env st conditions in
      return
        (Mu.mResource
           ((name, (pt_ret, SBT.proj oa_bt)), (loc, None))
           (Mu.mConstraints lcs lat))
    | Cn.CN_cletExpr (loc, name, expr') :: conditions ->
      let@ expr = Translate.expr Sym.Set.empty env st expr' in
      let@ lat = aux (Translate.add_logical name (IT.get_bt expr) env) st conditions in
      return (Mu.mDefine ((name, IT.Surface.proj expr), (loc, None)) lat)
    | Cn.CN_cconstr (loc, constr) :: conditions ->
      let@ lc = Translate.assrt env st (loc, constr) in
      let@ lat = aux env st conditions in
      return (Mu.mConstraint (lc, (loc, None)) lat)
    | [] ->
      let@ i = f_i env st in
      return (Mu.I i)
  in
  aux


let rec make_largs_with_accesses f_i env st (accesses, conditions) =
  match accesses with
  | (loc, (addr_s, ct)) :: accesses ->
    let@ name, ((pt_ret, oa_bt), lcs), value =
      Translate.ownership (loc, (addr_s, ct)) env
    in
    let env = Translate.add_logical name oa_bt env in
    let st = Translate.C_vars.add [ (addr_s, Points_to value) ] st in
    let@ lat = make_largs_with_accesses f_i env st (accesses, conditions) in
    return
      (Mu.mResource
         ((name, (pt_ret, SBT.proj oa_bt)), (loc, None))
         (Mu.mConstraints lcs lat))
  | [] -> make_largs f_i env st conditions


let is_pass_by_pointer = function By_pointer -> true | By_value -> false

let check_against_core_bt loc cbt bt =
  CoreTypeChecks.check_against_core_bt cbt bt
  |> Result.map_error (fun msg ->
    TypeErrors.{ loc; msg = Generic msg [@alert "-deprecated"] })


let make_label_args f_i loc env st args (accesses, inv) =
  let rec aux (resources, good_lcs) env st = function
    | ((o_s, (ct, pass_by_value_or_pointer)), (s, cbt)) :: rest ->
      assert (Option.equal Sym.equal o_s (Some s));
      let@ () = check_against_core_bt loc cbt (Loc ()) in
      assert (is_pass_by_pointer pass_by_value_or_pointer);
      (* now interesting only: s, ct, rest *)
      let sct = convert_ct loc ct in
      let p_sbt = BT.Loc (Some sct) in
      let env = Translate.add_computational s p_sbt env in
      (* let good_pointer_lc = *)
      (*   let info = (loc, Some (Sym.pp_string s ^ " good")) in *)
      (*   let here = Locations.other __LOC__ in *)
      (*   (LTranslate.T (IT.good_ (Pointer sct, IT.sym_ (s, BT.Loc, here)) here), info) *)
      (* in *)
      let@ oa_name, ((pt_ret, oa_bt), lcs), value =
        Translate.ownership (loc, (s, ct)) env
      in
      let env = Translate.add_logical oa_name oa_bt env in
      let st = Translate.C_vars.add [ (s, Points_to value) ] st in
      let owned_res = ((oa_name, (pt_ret, SBT.proj oa_bt)), (loc, None)) in
      let resources' =
        if !Sym.executable_spec_enabled then
          [ owned_res ]
        else (
          let alloc_res = Translate.allocation_token loc s in
          [ alloc_res; owned_res ])
      in
      let@ at =
        aux
          ( resources @ resources',
            good_lcs
            @
            (* good_pointer_lc :: *)
            lcs )
          env
          st
          rest
      in
      return (Mu.mComputational ((s, Loc ()), (loc, None)) at)
    | [] ->
      let@ lat = make_largs_with_accesses f_i env st (accesses, inv) in
      let at = Mu.mResources resources (Mu.mConstraints good_lcs lat) in
      return (Mu.L at)
  in
  aux ([], []) env st args


let make_function_args f_i loc env args accesses ghost_params requires =
  let rec aux_comp arg_states good_lcs env st = function
    | ((mut_arg, (mut_arg', ct)), (pure_arg, cbt)) :: rest ->
      assert (Option.equal Sym.equal (Some mut_arg) mut_arg');
      let ct = convert_ct loc ct in
      let sbt = Memory.sbt_of_sct ct in
      let bt = SBT.proj sbt in
      let@ () = check_against_core_bt loc cbt bt in
      let env = Translate.add_computational pure_arg sbt env in
      let arg_state = Translate.C_vars.Value (pure_arg, sbt) in
      let st = Translate.C_vars.add [ (mut_arg, arg_state) ] st in
      (* let good_lc = *)
      (*   let info = (loc, Some (Sym.pp_string pure_arg ^ " good")) in *)
      (*   let here = Locations.other __LOC__ in *)
      (*   (LTranslate.T (IT.good_ (ct, IT.sym_ (pure_arg, bt, here)) here), info) *)
      (* in *)
      let@ at =
        aux_comp
          (arg_states @ [ (mut_arg, arg_state) ])
          (* good_lc :: *) good_lcs
          env
          st
          rest
      in
      return (Mu.mComputational ((pure_arg, bt), (loc, None)) at)
    | [] ->
      let rec aux_ghost arg_states env st = function
        | (arg, cnbt) :: rest ->
          let sbt = Translate.base_type env cnbt in
          let bt = SBT.proj sbt in
          let env = Translate.add_logical arg sbt env in
          let@ at = aux_ghost arg_states env st rest in
          return (Mu.Ghost ((arg, bt), (loc, None), at))
        | [] ->
          let@ lat =
            make_largs_with_accesses (f_i arg_states) env st (accesses, requires)
          in
          return (Mu.L (Mu.mConstraints (List.rev good_lcs) lat))
      in
      aux_ghost arg_states env st ghost_params
  in
  aux_comp [] [] env Translate.C_vars.init args


let make_fun_with_spec_args f_i loc env args accesses ghost_params requires =
  let rec aux_comp good_lcs env st = function
    | ((pure_arg, cn_bt), ct_ct) :: rest ->
      let ct = convert_ct loc ct_ct in
      let sbt = Memory.sbt_of_sct ct in
      let bt = SBT.proj sbt in
      let sbt2 = Translate.base_type env cn_bt in
      let@ () =
        if BT.equal bt (SBT.proj sbt2) then
          return ()
        else
          fail
            { loc;
              msg =
                Generic
                  (!^"Argument-type mismatch between"
                   ^^^ BT.pp bt
                   ^^^ parens (!^"from" ^^^ Sctypes.pp ct)
                   ^^^ !^"and"
                   ^^^ BT.pp (SBT.proj sbt2))
                [@alert "-deprecated"]
            }
      in
      let env = Translate.add_computational pure_arg sbt env in
      (* let good_lc = *)
      (*   let info = (loc, Some (Sym.pp_string pure_arg ^ " good")) in *)
      (*   let here = Locations.other __LOC__ in *)
      (*   (LTranslate.T (IT.good_ (ct, IT.sym_ (pure_arg, bt, here)) here), info) *)
      (* in *)
      let@ at = aux_comp (* good_lc :: *) good_lcs env st rest in
      return (Mu.mComputational ((pure_arg, bt), (loc, None)) at)
    | [] ->
      let rec aux_ghost env st = function
        | (arg, cnbt) :: rest ->
          let sbt = Translate.base_type env cnbt in
          let bt = SBT.proj sbt in
          let env = Translate.add_logical arg sbt env in
          let@ at = aux_ghost env st rest in
          return (Mu.Ghost ((arg, bt), (loc, None), at))
        | [] ->
          let@ lat = make_largs_with_accesses f_i env st (accesses, requires) in
          return (Mu.L (Mu.mConstraints (List.rev good_lcs) lat))
      in
      aux_ghost env st ghost_params
  in
  aux_comp [] env Translate.C_vars.init args


let desugar_access d_st global_types (loc, id) =
  let@ s, var_kind = do_ail_desugar_rdonly d_st (CAE.resolve_cn_ident CN_vars id) in
  let@ () =
    match var_kind with
    | Var_kind_c C_kind_var -> return ()
    | Var_kind_c C_kind_enum ->
      fail
        { loc;
          msg =
            Generic !^"accesses: expected global, not enum constant"
            [@alert "-deprecated"]
        }
    | Var_kind_cn ->
      let msg =
        !^"The name"
        ^^^ squotes (Id.pp id)
        ^^^ !^"is not bound to a C global variable."
        ^^^ !^"Perhaps it has been shadowed by a CN variable?"
      in
      fail { loc; msg = Generic msg [@alert "-deprecated"] }
  in
  let@ ct =
    match List.assoc_opt Sym.equal s global_types with
    | Some ct -> return (convert_ct loc ct)
    | None ->
      fail
        { loc; msg = Generic (Sym.pp s ^^^ !^"is not a global") [@alert "-deprecated"] }
  in
  let ct = Sctypes.to_ctype ct in
  return (loc, (s, ct))


let desugar_cond d_st = function
  | Cn.CN_cletResource (loc, id, res) ->
    debug 6 (lazy (typ (string "desugaring a let-resource at") (Locations.pp loc)));
    let@ res = do_ail_desugar_rdonly d_st (Desugar.cn_resource res) in
    let@ sym, d_st = register_new_cn_local id d_st in
    return (Cn.CN_cletResource (loc, sym, res), d_st)
  | Cn.CN_cletExpr (loc, id, expr) ->
    debug 6 (lazy (typ (string "desugaring a let-expr at") (Locations.pp loc)));
    let@ expr = do_ail_desugar_rdonly d_st (Desugar.cn_expr expr) in
    let@ sym, d_st = register_new_cn_local id d_st in
    return (Cn.CN_cletExpr (loc, sym, expr), d_st)
  | Cn.CN_cconstr (loc, constr) ->
    debug 6 (lazy (typ (string "desugaring a constraint at") (Locations.pp loc)));
    let@ constr = do_ail_desugar_rdonly d_st (Desugar.cn_assertion constr) in
    return (Cn.CN_cconstr (loc, constr), d_st)


let desugar_conds d_st conds =
  let@ conds, d_st =
    ListM.fold_leftM
      (fun (conds, d_st) cond ->
         let@ cond, d_st = desugar_cond d_st cond in
         return (cond :: conds, d_st))
      ([], d_st)
      conds
  in
  return (List.rev conds, d_st)


let dtree_of_conds = List.map CF.Cn_ocaml.PpAil.dtree_of_cn_condition

let dtree_of_inv conds =
  let open CF.Pp_ast in
  Dnode (pp_ctor "LoopInvariantAnnotation", dtree_of_conds conds)


let dtree_of_requires conds =
  let open CF.Pp_ast in
  Dnode (pp_ctor "RequiresAnnotation", dtree_of_conds conds)


let dtree_of_ensures conds =
  let open CF.Pp_ast in
  Dnode (pp_ctor "EnsuresAnnotation", dtree_of_conds conds)


let dtree_of_ghost_args args =
  let open CF.Pp_ast in
  Dnode (pp_ctor "GhostArguments", CF.Cn_ocaml.PpAil.dtrees_of_cn_ghosts args)


let dtree_of_accesses accesses =
  let open CF.Pp_ast in
  Dnode
    ( pp_ctor "AccessesAnnotation",
      List.map
        (fun (_loc, (s, ct)) ->
           Dnode
             (pp_ctor "Access", [ Dleaf (Sym.pp s); Dleaf (CF.Pp_core_ctype.pp_ctype ct) ]))
        accesses )


let normalise_label
      ~inherit_loc
      fsym
      (markers_env, precondition_cn_desugaring_state)
      (global_types, visible_objects_env)
      (accesses, (loop_attributes : CF.Annot.loop_attributes))
      (env : Translate.env)
      st
      _label_name
      label
  =
  match label with
  | CF.Milicore.Mi_Return loc -> return (Mu.Return loc)
  | Mi_Label (loc, lt, label_args, label_body, annots) ->
    (match CF.Annot.get_label_annot annots with
     | Some (LAloop loop_id) ->
       let@ desugared_inv, cn_desugaring_state, loop_info =
         match Pmap.lookup loop_id loop_attributes with
         | Some { marker_id; attributes = attrs; loc_condition; loc_loop } ->
           let@ inv = Parse.loop_spec attrs in
           let contains_user_spec = List.non_empty inv in
           let d_st =
             CAE.
               { markers_env;
                 inner =
                   { (Pmap.find marker_id markers_env) with
                     cn_state = precondition_cn_desugaring_state
                   }
               }
           in
           let@ inv, d_st = desugar_conds d_st inv in
           return (inv, d_st.inner.cn_state, (loc_condition, loc_loop, contains_user_spec))
         | None -> assert false
         (* return ([], precondition_cn_desugaring_state) *)
       in
       debug 6 (lazy (!^"invariant in function" ^^^ Sym.pp fsym));
       debug 6 (lazy (CF.Pp_ast.pp_doc_tree (dtree_of_inv desugared_inv)));
       let@ label_args_and_body =
         make_label_args
           (fun env st ->
              n_expr
                ~inherit_loc
                loc
                ( (env, Translate.C_vars.get_old_scopes st),
                  (markers_env, cn_desugaring_state) )
                (global_types, visible_objects_env)
                label_body)
           loc
           env
           st
           (List.combine lt label_args)
           (accesses, desugared_inv)
       in
       (* let lt =  *)
       (*   at_of_arguments (fun _body -> *)
       (*       False.False *)
       (*     ) label_args_and_body  *)
       (* in *)
       return
         (Mu.Label
            ( loc,
              label_args_and_body,
              annots,
              { label_spec = desugared_inv },
              `Loop loop_info ))
     (* | Some (LAloop_body _loop_id) -> *)
     (*    assert_error loc !^"body label has not been inlined" *)
     | Some (LAloop_continue _loop_id) ->
       assert_error loc !^"continue label has not been inlined"
     | Some (LAloop_break _loop_id) ->
       assert_error loc !^"break label has not been inlined"
     | Some LAreturn -> assert_error loc !^"return label has not been inlined"
     | Some LAswitch -> assert_error loc !^"switch labels"
     | Some LAcase -> assert_error loc !^"case label has not been inlined"
     | Some LAdefault -> assert_error loc !^"default label has not been inlined"
     | Some LAactual_label -> failwith "todo: associate invariant with label or inline"
     | None -> assert_error loc !^"non-loop labels")


module Spec = struct
  type 'a parsed =
    { trusted : Mu.trusted;
      accesses : (Cerb_location.t * Id.t) list;
      ghost_params : (Cerb_location.t * (Id.t * Id.t Cn.cn_base_type)) list;
      requires : (Cerb_location.t * (Id.t, 'a) Cn.cn_condition) list;
      ensures : (Cerb_location.t * (Id.t, 'a) Cn.cn_condition) list;
      functions : (Cerb_location.t * Id.t) list;
      if_spec : (int * Cerb_location.t * (Id.t * Id.t Cn.cn_base_type) list) option
    }

  let default : _ parsed =
    { trusted = Mucore.Checked;
      accesses = [];
      ghost_params = [];
      requires = [];
      ensures = [];
      functions = [];
      if_spec = None
    }


  let process
        ?if_spec
        Cn.{ cn_func_trusted; cn_func_acc_func; cn_func_requires; cn_func_ensures }
    : _ parsed
    =
    let cross_fst x =
      match x with None -> [] | Some (a, bs) -> List.map (fun b -> (a, b)) bs
    in
    (* TODO: replace cross_fst2 with correct locations:
      https://github.com/rems-project/cn/issues/200 *)
    let cross_fst2 x =
      match x with
      | None -> ([], [])
      | Some (a, (bs, cs)) -> (cross_fst (Some (a, bs)), cross_fst (Some (a, cs)))
    in
    let trusted =
      match cn_func_trusted with None -> Mucore.Checked | Some loc -> Mucore.Trusted loc
    in
    let accesses, functions =
      match cn_func_acc_func with
      | None -> ([], [])
      | Some (loc, Cn.CN_mk_function nm) -> ([], [ (loc, nm) ])
      | Some (loc, Cn.CN_accesses ids) -> (cross_fst (Some (loc, ids)), [])
    in
    let ghost_params, requires = cross_fst2 cn_func_requires in
    let cn_func_ensures =
      Option.map (fun (loc, (_ghost, conds)) -> (loc, conds)) cn_func_ensures
    in
    let ensures = cross_fst cn_func_ensures in
    { trusted; accesses; ghost_params; requires; ensures; functions; if_spec }


  let there_can_only_be_one defn_loc fname parsed_decl_spec parsed_defn_specs =
    let _ : (_ * _ Cn.cn_decl_spec) list = parsed_decl_spec in
    match (parsed_decl_spec, parsed_defn_specs) with
    (* No specs *)
    | [], None -> return default
    (* Definition spec *)
    | [], Some parsed_defn_specs -> return (process parsed_defn_specs)
    (* Single decl spec *)
    | [ (decl_marker, parsed_decl_spec) ], None ->
      return
        (process
           ~if_spec:
             (decl_marker, parsed_decl_spec.cn_decl_loc, parsed_decl_spec.cn_decl_args)
           parsed_decl_spec.cn_func_spec)
    (* Multiple decl specs: not supported due to variable re-binding complexity *)
    | (_, spec) :: (_, spec') :: _, None ->
      let loc, orig_loc = (spec'.cn_decl_loc, spec.cn_decl_loc) in
      fail { loc; msg = Double_spec { fname; orig_loc } }
    (* Decl and definition spec: user error *)
    | (_, decl_spec) :: _, Some _ ->
      let loc, orig_loc = (defn_loc, decl_spec.cn_decl_loc) in
      fail { loc; msg = Double_spec { fname; orig_loc } }


  let desugar_and_add_args decl_d_st spec_args =
    do_ail_desugar_op decl_d_st
    @@ CF.State_exception.stExpect_mapM (Desugar.cn_arg Cn.CN_vars) spec_args


  let add_spec_arg_renames loc args arg_cts cn_spec_args env =
    List.fold_right
      (fun ((fun_sym, _), (ct, (spec_sym, _))) env ->
         Translate.add_renamed_computational
           spec_sym
           fun_sym
           (Memory.sbt_of_sct (convert_ct loc ct))
           env)
      (List.combine args (List.combine arg_cts cn_spec_args))
      env


  let setup_env_desugaring_state loc defn_marker markers_env if_spec env args arg_cts =
    match if_spec with
    | None -> return (env, CAE.{ inner = Pmap.find defn_marker markers_env; markers_env })
    | Some (decl_marker, _spec_loc, spec_args) ->
      let decl_d_st = CAE.{ inner = Pmap.find decl_marker markers_env; markers_env } in
      let@ spec_args, decl_d_st = desugar_and_add_args decl_d_st spec_args in
      return (add_spec_arg_renames loc args arg_cts spec_args env, decl_d_st)


  let logical_fun_syms d_st mk_functions =
    ListM.mapM
      (fun (loc, id) ->
         (* from Thomas's convert_c_logical_funs *)
         let@ logical_fun_sym = do_ail_desugar_rdonly d_st (CAE.lookup_cn_function id) in
         return (loc, logical_fun_sym))
      mk_functions


  type desugared =
    { trusted : Mu.trusted;
      accesses : (Cerb_location.t * (Sym.t * Ctype.ctype)) list;
      ghost_params : (Sym.t * Sym.t Cn.cn_base_type) list;
      requires : (Sym.t, Ctype.ctype) Cn.cn_condition list;
      ensures : (Sym.t, Ctype.ctype) Cn.cn_condition list;
      functions : (Cerb_location.t * Sym.t) list
    }

  let desugar
        global_types
        d_st
        ({ trusted; accesses; ghost_params; requires; ensures; functions; if_spec = _ } :
          _ parsed)
    : (desugared * _ * _) t
    =
    let@ functions = logical_fun_syms d_st functions in
    let@ accesses = ListM.mapM (desugar_access d_st global_types) accesses in
    let@ ghost_params, d_st = desugar_and_add_args d_st (List.map snd ghost_params) in
    let@ requires, d_st = desugar_conds d_st (List.map snd requires) in
    debug 6 (lazy (string "desugared requires conds"));
    let here = Locations.other __LOC__ in
    let@ ret_s, ret_d_st = register_new_cn_local (Id.make here "return") d_st in
    let@ ensures, _ = desugar_conds ret_d_st (List.map snd ensures) in
    debug 6 (lazy (string "desugared ensures conds"));
    return
      ({ trusted; accesses; ghost_params; requires; ensures; functions }, ret_s, ret_d_st)
end

let normalise_fun_map_decl
      ~inherit_loc
      (markers_env, ail_prog)
      (global_types, visible_objects_env)
      env
      fun_specs
      (funinfo : CF.Milicore.mi_funinfo)
      loop_attributes
      fname
      decl
  =
  match Pmap.lookup fname funinfo with
  | None -> return None
  | Some (loc, attrs, ret_ct, arg_cts, variadic, _) ->
    let@ () = if variadic then unsupported loc !^"variadic functions" else return () in
    (match decl with
     | CF.Milicore.Mi_Fun (_bt, _args, _pe) -> assert false
     | Mi_Proc (loc, _mrk, _ret_bt, args, body, labels) ->
       debug 2 (lazy (item "normalising procedure" (Sym.pp fname)));
       let@ parsed_defn_specs = Parse.function_spec attrs in
       let parsed_decl_spec =
         Option.fold (Sym.Map.find_opt fname fun_specs) ~none:[] ~some:Fun.id
       in
       let@ parsed =
         Spec.there_can_only_be_one loc fname parsed_decl_spec parsed_defn_specs
       in
       debug 6 (lazy (string "parsed spec attrs"));
       let _, defn_marker, _, ail_args, _ =
         List.assoc Sym.equal fname ail_prog.CF.AilSyntax.function_definitions
       in
       let@ env, d_st =
         Spec.setup_env_desugaring_state
           loc
           defn_marker
           markers_env
           parsed.if_spec
           env
           args
           (List.map snd arg_cts)
       in
       let@ { trusted; accesses; ghost_params; requires; ensures; functions }, ret_s, d_st
         =
         Spec.desugar global_types d_st parsed
       in
       debug 6 (lazy (!^"function requires/ensures" ^^^ Sym.pp fname));
       debug 6 (lazy (CF.Pp_ast.pp_doc_tree (dtree_of_accesses accesses)));
       debug 6 (lazy (CF.Pp_ast.pp_doc_tree (dtree_of_ghost_args ghost_params)));
       debug 6 (lazy (CF.Pp_ast.pp_doc_tree (dtree_of_requires requires)));
       debug 6 (lazy (CF.Pp_ast.pp_doc_tree (dtree_of_ensures ensures)));
       let@ args_and_body =
         make_function_args
           (fun arg_states env st ->
              let st = Translate.C_vars.push_scope st Translate.C_vars.start in
              let@ body =
                n_expr
                  ~inherit_loc
                  loc
                  ( (env, Translate.C_vars.get_old_scopes st),
                    (markers_env, d_st.inner.cn_state) )
                  (global_types, visible_objects_env)
                  body
              in
              let@ returned =
                Translate.return_type
                  loc
                  env
                  (Translate.C_vars.add arg_states st)
                  (ret_s, ret_ct)
                  (accesses, ensures)
              in
              let@ labels =
                PmapM.mapM
                  (normalise_label
                     ~inherit_loc
                     fname
                     (markers_env, CAE.(d_st.inner.cn_state))
                     (global_types, visible_objects_env)
                     (accesses, loop_attributes)
                     env
                     st)
                  labels
                  Sym.compare
              in
              return (body, labels, returned))
           loc
           env
           (List.combine (List.combine ail_args arg_cts) args)
           accesses
           ghost_params
           requires
       in
       return (Some (Mu.Proc { loc; args_and_body; trusted }, functions))
     | Mi_ProcDecl (loc, ret_bt, _bts) ->
       (match Sym.Map.find_opt fname fun_specs with
        | Some parsed_decl_spec ->
          let@ () =
            check_against_core_bt loc ret_bt (Memory.bt_of_sct (convert_ct loc ret_ct))
          in
          let@ parsed = Spec.there_can_only_be_one loc fname parsed_decl_spec None in
          let ail_marker, spec_loc, spec_args = Option.get parsed.if_spec in
          let d_st = CAE.{ inner = Pmap.find ail_marker markers_env; markers_env } in
          let@ spec_args, d_st = Spec.desugar_and_add_args d_st spec_args in
          let@ ( { trusted = _; accesses; ghost_params; requires; ensures; functions },
                 ret_s,
                 _ )
            =
            Spec.desugar global_types d_st parsed
          in
          let@ () =
            let spec = List.length spec_args in
            let decl = List.length arg_cts in
            if spec != decl then
              fail { loc = spec_loc; msg = Number_spec_args { spec; decl } }
            else
              return ()
          in
          let@ args_and_rt =
            make_fun_with_spec_args
              (fun env st ->
                 let@ returned =
                   Translate.return_type loc env st (ret_s, ret_ct) (accesses, ensures)
                 in
                 return returned)
              loc
              env
              (List.combine spec_args (List.map snd arg_cts))
              accesses
              ghost_params
              requires
          in
          let ft = at_of_arguments Tools.id args_and_rt in
          return (Some (Mu.ProcDecl (loc, Some ft), functions))
        | _ -> return (Some (Mu.ProcDecl (loc, None), [])))
     | Mi_BuiltinDecl (_loc, _bt, _bts) -> assert false)


(* BuiltinDecl(loc, convert_bt loc bt, List.map (convert_bt loc) bts) *)

let normalise_fun_map
      ~inherit_loc
      (markers_env, ail_prog)
      (global_types, visible_objects_env)
      env
      fun_specs
      funinfo
      loop_attributes
      fmap
  =
  let@ fmap, mk_functions, failed =
    PmapM.foldM
      (fun fsym fdecl (fmap, mk_functions, failed) ->
         try
           let@ r =
             normalise_fun_map_decl
               ~inherit_loc
               (markers_env, ail_prog)
               (global_types, visible_objects_env)
               env
               fun_specs
               funinfo
               loop_attributes
               fsym
               fdecl
           in
           match r with
           | Some (fdecl, more_mk_functions) ->
             let mk_functions' =
               List.map
                 (fun (loc, lsym) -> Mu.{ c_fun_sym = fsym; loc; l_fun_sym = lsym })
                 more_mk_functions
             in
             return (Pmap.add fsym fdecl fmap, mk_functions' @ mk_functions, failed)
           | None -> return (fmap, mk_functions, failed)
         with
         | ConversionFailed -> return (fmap, mk_functions, true))
      fmap
      (Pmap.empty Sym.compare, [], false)
  in
  if failed then
    exit 2
  else
    return (fmap, mk_functions)


let normalise_globs ~inherit_loc env _sym g =
  let loc = Locations.other __LOC__ in
  match g with
  | GlobalDef ((bt, ct), e) ->
    let@ () = check_against_core_bt loc bt BT.(Loc ()) in
    (* this may have to change *)
    let@ e =
      n_expr
        ~inherit_loc
        loc
        ( (env, Translate.C_vars.(get_old_scopes init)),
          ( Pmap.empty Int.compare,
            CF.Cn_desugaring.(initial_cn_desugaring_state empty_init) ) )
        ([], Pmap.empty Int.compare)
        e
    in
    return (Mu.GlobalDef (convert_ct loc ct, e))
  | GlobalDecl (bt, ct) ->
    let@ () = check_against_core_bt loc bt BT.(Loc ()) in
    return (Mu.GlobalDecl (convert_ct loc ct))


let normalise_globs_list ~inherit_loc env gs =
  ListM.mapM
    (fun (sym, g) ->
       let@ g = normalise_globs ~inherit_loc env sym g in
       return (sym, g))
    gs


let make_struct_decl loc fields (tag : Sym.t) =
  let open Memory in
  let tagDefs = CF.Tags.tagDefs () in
  let member_offset member =
    Memory.int_of_ival (CF.Impl_mem.offsetof_ival tagDefs tag member)
  in
  let final_position = Memory.size_of_ctype (Struct tag) in
  let rec aux members position =
    match members with
    | [] ->
      if position < final_position then
        [ { offset = position;
            size = final_position - position;
            member_or_padding = None
          }
        ]
      else
        []
    | (member, (_attrs, _ (*align_opt*), _qualifiers, ct)) :: members ->
      (* TODO: support for any alignment specifier *)
      let sct = convert_ct loc ct in
      let offset = member_offset member in
      let size = Memory.size_of_ctype sct in
      let to_pad = offset - position in
      let padding =
        if to_pad > 0 then
          [ { offset = position; size = to_pad; member_or_padding = None } ]
        else
          []
      in
      let member = [ { offset; size; member_or_padding = Some (member, sct) } ] in
      let rest = aux members (offset + size) in
      padding @ member @ rest
  in
  aux fields 0


let normalise_tag_definition tag (loc, def) =
  match def with
  | Ctype.StructDef (_fields, Some (FlexibleArrayMember (_, Identifier (loc, _), _, _)))
    ->
    unsupported loc !^"flexible array members"
  | StructDef (fields, None) -> return (Mu.StructDef (make_struct_decl loc fields tag))
  | UnionDef _l -> unsupported loc !^"union types"


let normalise_tag_definitions tagDefs =
  Pmap.fold
    (fun tag def acc ->
       let@ acc in
       let@ normed = normalise_tag_definition tag def in
       return (Pmap.add tag normed acc))
    tagDefs
    (return (Pmap.empty Sym.compare))


let register_glob env (sym, glob) =
  match glob with
  | Mu.GlobalDef (ct, _e) -> Translate.add_computational sym (BT.Loc (Some ct)) env
  | GlobalDecl ct -> Translate.add_computational sym (BT.Loc (Some ct)) env


let translate_datatype env Cn.{ cn_dt_loc; cn_dt_name; cn_dt_cases; cn_dt_magic_loc = _ } =
  let translate_arg (id, bt) = (id, SBT.proj (Translate.base_type env bt)) in
  let cases = List.map (fun (c, args) -> (c, List.map translate_arg args)) cn_dt_cases in
  (cn_dt_name, Mu.{ loc = cn_dt_loc; cases })


let normalise_file ~inherit_loc ((fin_markers_env : CAE.fin_markers_env), ail_prog) file =
  let open CF.AilSyntax in
  let open CF.Milicore in
  let@ tagDefs = normalise_tag_definitions file.mi_tagDefs in
  let fin_marker, markers_env = fin_markers_env in
  let fin_d_st = CAE.{ inner = Pmap.find fin_marker markers_env; markers_env } in
  let env = Translate.init tagDefs (fetch_enum fin_d_st) (fetch_typedef fin_d_st) in
  let@ env = Translate.add_datatypes env ail_prog.cn_datatypes in
  (* Builtin functions that can be expressed as index terms are added in Translate.init *)
  let@ env = Translate.add_user_defined_functions env ail_prog.cn_functions in
  let@ lfuns = ListM.mapM (Translate.function_ env) ail_prog.cn_functions in
  let env = Translate.add_predicates env ail_prog.cn_predicates in
  let@ preds = ListM.mapM (Translate.predicate env) ail_prog.cn_predicates in
  let@ lemmata = ListM.mapM (Translate.lemma env) ail_prog.cn_lemmata in
  let global_types =
    List.map
      (fun (s, global) ->
         match global with
         | GlobalDef ((_bt, ct), _e) -> (s, ct)
         | GlobalDecl (_bt, ct) -> (s, ct))
      file.mi_globs
  in
  let@ globs = normalise_globs_list ~inherit_loc env file.mi_globs in
  let env = List.fold_left register_glob env globs in
  let add_to_list key value list_map =
    (* Map.add_to_list exists in OCaml 5.1, this is because we currently build
     * with 4.14 *)
    Sym.Map.update
      key
      (function None -> Some [ value ] | Some vs -> Some (value :: vs))
      list_map
  in
  let fun_specs_map =
    List.fold_right
      (fun (id, key, spec) acc -> add_to_list key (id, spec) acc)
      ail_prog.cn_decl_specs
      Sym.Map.empty
  in
  let@ funs, mk_functions =
    normalise_fun_map
      ~inherit_loc
      (markers_env, ail_prog)
      (global_types, file.mi_visible_objects_env)
      env
      fun_specs_map
      file.mi_funinfo
      file.mi_loop_attributes
      file.mi_funs
  in
  let call_funinfo =
    Pmap.mapi
      (fun _fsym (_, _, ret, args, variadic, has_proto) ->
         Sctypes.
           { sig_return_ty = ret;
             sig_arg_tys = List.map snd args;
             sig_variadic = variadic;
             sig_has_proto = has_proto
           })
      file.mi_funinfo
  in
  let stdlib_syms = Sym.Set.of_list (List.map fst (Pmap.bindings_list file.mi_stdlib)) in
  let datatypes = List.map (translate_datatype env) ail_prog.cn_datatypes in
  let builtin_lfuns =
    List.map (fun (_, sym, def) -> (sym, def)) Builtins.builtin_fun_defs
  in
  let file =
    Mu.
      { main = file.mi_main;
        tagDefs;
        globs;
        funs;
        extern = file.mi_extern;
        stdlib_syms;
        mk_functions;
        resource_predicates = preds;
        (* Add user defined functions here along with certain builtins that can be
         easily expressed with index terms *)
        logical_predicates = builtin_lfuns @ lfuns;
        datatypes;
        lemmata;
        call_funinfo
      }
  in
  debug 3 (lazy (headline "done core_to_mucore normalising file"));
  return file
