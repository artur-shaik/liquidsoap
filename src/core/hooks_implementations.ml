module Hooks = Liquidsoap_lang.Hooks
module Lang = Liquidsoap_lang.Lang

(* For source eval check there are cases of:
     source('a) <: (source('a).{ source methods })?
   b/c of source.dynamic so we want to dig deeper
   than the regular demeth. *)
let rec deep_demeth t =
  match Type.demeth t with
    | Type.{ descr = Nullable t } -> deep_demeth t
    | t -> t

let eval_check ~env:_ ~tm v =
  if Lang_source.Source_val.is_value v then (
    let s = Lang_source.Source_val.of_value v in
    if not s#has_content_type then (
      let ty = Type.fresh (deep_demeth tm.Term.t) in
      Typing.(Lang_source.source_t ~methods:false s#frame_type <: ty);
      s#content_type_computation_allowed))
  else if Track.is_value v then (
    let field, source = Lang_source.to_track v in
    if not source#has_content_type then (
      match field with
        | _ when field = Frame.Fields.metadata -> ()
        | _ when field = Frame.Fields.track_marks -> ()
        | _ ->
            let ty = Type.fresh (deep_demeth tm.Term.t) in
            let frame_t =
              Frame_type.make (Lang.univ_t ())
                (Frame.Fields.add field ty Frame.Fields.empty)
            in
            Typing.(source#frame_type <: frame_t)))

let render_string = function
  | `Verbatim s -> s
  | `String (pos, (sep, s)) -> Liquidsoap_lang.Lexer.render_string ~pos ~sep s

let mk_field_t ~pos kind params =
  match kind with
    | "any" -> Type.var ~pos ()
    | "none" | "never" -> Type.make Type.Ground.never
    | _ -> (
        try
          let k = Content.kind_of_string kind in
          match params with
            | [] -> Type.make (Format_type.descr (`Kind k))
            | [("", `Verbatim "any")] -> Type.var ()
            | [("", `Verbatim "internal")] ->
                Type.var ~constraints:[Format_type.internal_tracks] ()
            | param :: params ->
                let mk_format (label, value) =
                  let value = render_string value in
                  Content.parse_param k label value
                in
                let f = mk_format param in
                List.iter
                  (fun param -> Content.merge f (mk_format param))
                  params;
                assert (k = Content.kind f);
                Type.make (Format_type.descr (`Format f))
        with _ ->
          let params =
            params
            |> List.map (fun (l, v) -> l ^ "=" ^ render_string v)
            |> String.concat ","
          in
          let t = kind ^ "(" ^ params ^ ")" in
          raise
            (Liquidsoap_lang.Term_base.Parse_error
               (pos, "Unknown type constructor: " ^ t ^ ".")))

let mk_source_ty ?pos name { Liquidsoap_lang.Parsed_term.extensible; tracks } =
  let pos = Option.value ~default:(Lexing.dummy_pos, Lexing.dummy_pos) pos in

  if name <> "source" then
    raise
      (Liquidsoap_lang.Term_base.Parse_error
         (pos, "Unknown type constructor: " ^ name ^ "."));

  match tracks with
    | [] ->
        Lang_source.source_t
          (Frame_type.make (Lang.univ_t ()) Frame.Fields.empty)
    | tracks ->
        let fields =
          List.fold_left
            (fun fields
                 {
                   Liquidsoap_lang.Parsed_term.track_name;
                   track_type;
                   track_params;
                 } ->
              Frame.Fields.add
                (Frame.Fields.field_of_string track_name)
                (mk_field_t ~pos track_type track_params)
                fields)
            Frame.Fields.empty tracks
        in
        let base = if extensible then Lang.univ_t () else Lang.unit_t in

        Lang_source.source_t (Frame_type.make base fields)

let register () =
  Hooks.liq_libs_dir := Configure.liq_libs_dir;
  let on_change v =
    Hooks.log_path :=
      if v then (try Some Dtools.Log.conf_file_path#get with _ -> None)
      else None
  in
  Dtools.Log.conf_file#on_change on_change;
  ignore (Option.map on_change Dtools.Log.conf_file#get_d);
  Hooks.collect_after := Clock.collect_after;
  (Hooks.make_log := fun name -> (Log.make name :> Hooks.log));
  Hooks.type_of_encoder := Lang_encoder.type_of_encoder;
  Hooks.make_encoder := Lang_encoder.make_encoder;
  Hooks.eval_check := eval_check;
  (Hooks.has_encoder :=
     fun fmt ->
       try
         let (_ : Encoder.factory) =
           Encoder.get_factory (Lang_encoder.V.of_value fmt)
         in
         true
       with _ -> false);
  Hooks.mk_source_ty := mk_source_ty;
  Hooks.getpwnam := Unix.getpwnam;
  Hooks.source_methods_t :=
    fun () -> Lang_source.source_t ~methods:true (Lang.univ_t ())
