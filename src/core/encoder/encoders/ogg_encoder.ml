(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2023 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA

 *****************************************************************************)

(** OGG encoder *)

open Mm

type track = {
  encode : Ogg_muxer.t -> nativeint -> Frame.t -> int -> int -> unit;
  reset : Ogg_muxer.t -> Frame.Metadata.Export.t -> nativeint;
  mutable id : nativeint option;
}

let audio_encoders = Hashtbl.create 3
let theora_encoder = ref None

(** Helper to encode audio *)
let encode_audio ~channels ~src_freq ~dst_freq () =
  let samplerate_converter = Audio_converter.Samplerate.create channels in
  (* start and len are in main ticks. *)
  let encode encoder id frame start len =
    let b = AFrame.pcm frame in
    let start = Frame.audio_of_main start in
    let len = Frame.audio_of_main len in
    let buf, start, len =
      Audio_converter.Samplerate.resample samplerate_converter
        (dst_freq /. src_freq) b start len
    in
    let data =
      Ogg_muxer.Audio_data
        { Ogg_muxer.data = buf; offset = start; length = len }
    in
    Ogg_muxer.encode encoder id data
  in
  encode

(** Helper to encode video. *)
let encode_video encoder id frame start len =
  let data =
    VFrame.data frame |> Array.map (fun img -> Video.Canvas.Image.render img)
  in
  let start = Frame.video_of_main start in
  let len = Frame.video_of_main len in
  let data =
    Ogg_muxer.Video_data { Ogg_muxer.data; offset = start; length = len }
  in
  Ogg_muxer.encode encoder id data

let encoder_name = function
  | Ogg_format.Vorbis _ -> "vorbis"
  | Ogg_format.Opus _ -> "opus"
  | Ogg_format.Flac _ -> "flac"
  | Ogg_format.Speex _ -> "speex"

let get_encoder ~pos name =
  try Hashtbl.find audio_encoders name
  with Not_found ->
    Lang_encoder.raise_error ~pos
      (Printf.sprintf "Could not find any %s encoder." name)

let encoder ~pos { Ogg_format.audio; video } =
  ignore (Option.map (fun p -> get_encoder ~pos (encoder_name p)) audio);
  ignore (Option.map (fun _ -> assert (!theora_encoder <> None)) video);
  fun name meta ->
    let tracks = [] in
    let tracks =
      match audio with
        | Some params ->
            let enc = get_encoder ~pos (encoder_name params) in
            enc params :: tracks
        | None -> tracks
    in
    let tracks =
      match video with
        | Some params ->
            let enc = Option.get !theora_encoder in
            enc params :: tracks
        | None -> tracks
    in
    (* We add a skeleton only
     * if there are more than one stream for now. *)
    let skeleton = List.length tracks > 1 in
    let ogg_enc = Ogg_muxer.create ~skeleton name in
    let rec enc =
      {
        Encoder.insert_metadata;
        hls = Encoder.dummy_hls (fun _ _ -> assert false);
        encode;
        header = (fun () -> Ogg_muxer.get_header ogg_enc);
        stop;
      }
    and streams_start () =
      let f track =
        match track.id with
          | Some _ -> ()
          | None -> track.id <- Some (track.reset ogg_enc meta)
      in
      List.iter f tracks;
      Ogg_muxer.streams_start ogg_enc
    and encode frame start len =
      (* We do a lazy start, to
       * avoid empty streams at beginning.. *)
      if Ogg_muxer.state ogg_enc <> Ogg_muxer.Streaming then streams_start ();
      let f track =
        track.encode ogg_enc (Option.get track.id) frame start len
      in
      List.iter f tracks;
      Ogg_muxer.get_data ogg_enc
    and ogg_stop () =
      let f track = track.id <- None in
      List.iter f tracks;
      if Ogg_muxer.state ogg_enc = Ogg_muxer.Streaming then
        Ogg_muxer.end_of_stream ogg_enc
    and stop () =
      ogg_stop ();
      Ogg_muxer.get_data ogg_enc
    and insert_metadata m =
      ogg_stop ();
      let f track = track.id <- Some (track.reset ogg_enc m) in
      List.iter f tracks
    in
    { enc with hls = Encoder.dummy_hls encode }

let () =
  Plug.register Encoder.plug "ogg" ~doc:"ogg encoder." (function
    | Encoder.Ogg m -> Some (fun ?hls:_ ~pos v -> encoder ~pos m v)
    | _ -> None)
