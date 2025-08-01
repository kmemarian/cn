val debug_constraint_failure_diagnostics
  :  int ->
  Solver.model_with_q ->
  Simplify.simp_ctxt ->
  LogicalConstraints.t ->
  unit

module General : sig
  type uiinfo = Error_common.situation * TypeErrors.RequestChain.t

  val ftyp_args_request_step
    :  ([ `Rename of Sym.t | `Term of IndexTerms.t ] Subst.t -> 'a -> 'a) ->
    Locations.t ->
    uiinfo ->
    'b ->
    'a LogicalArgumentTypes.t ->
    'a LogicalArgumentTypes.t Typing.m

  val predicate_request_scan
    :  Locations.t ->
    Request.Predicate.t ->
    (Request.Predicate.t * Resource.output) option Typing.m
end

module Special : sig
  val check_live_alloc
    :  [ `Copy_alloc_id | `Ptr_cmp | `Ptr_diff | `ISO_array_shift | `ISO_member_shift ] ->
    Locations.t ->
    IndexTerms.t ->
    unit Typing.m

  val predicate_request
    :  Locations.t ->
    Error_common.situation ->
    Request.Predicate.t * (Locations.t * string) option ->
    Resource.predicate Typing.m

  val has_predicate
    :  Locations.t ->
    Error_common.situation ->
    Request.Predicate.t * (Locations.t * string) option ->
    bool Typing.m

  val qpredicate_request
    :  Locations.t ->
    Error_common.situation ->
    Request.QPredicate.t * (Locations.t * string) option ->
    Resource.qpredicate Typing.m
end
