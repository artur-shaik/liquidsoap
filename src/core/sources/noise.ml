(*****************************************************************************

  Liquidsoap, a programmable stream generator.
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

open Mm

(** Generate a white noise *)

class noise duration =
  object (self)
    inherit Synthesized.source ~seek:true ~name:"noise" duration

    method private synthesize length =
      let audio_len = Frame.audio_of_main length in
      let video_len = Frame.video_of_main length in

      Frame.Fields.fold
        (fun field typ frame ->
          match typ with
            | _ when Content.Audio.is_format typ ->
                let data = Content.Audio.get_data (Frame.get frame field) in
                Audio.Generator.white_noise data 0 audio_len;
                Frame.set frame field (Content.Audio.lift_data ~length data)
            (* This is not optimal. *)
            | _ when Content_pcm_s16.is_format typ ->
                let pcm = Content_pcm_s16.get_data (Frame.get frame field) in
                let audio = Content_pcm_s16.to_audio pcm in
                Audio.Generator.white_noise audio 0 audio_len;
                Content_pcm_s16.blit_audio audio 0 pcm 0 audio_len;
                Frame.set frame field (Content_pcm_s16.lift_data ~length pcm)
            | _ when Content_pcm_f32.is_format typ ->
                let pcm = Content_pcm_f32.get_data (Frame.get frame field) in
                let audio = Content_pcm_f32.to_audio pcm in
                Audio.Generator.white_noise audio 0 audio_len;
                Content_pcm_f32.blit_audio audio 0 pcm 0 audio_len;
                Frame.set frame field (Content_pcm_f32.lift_data ~length pcm)
            | _ when Content.Video.is_format typ ->
                let data = Content.Video.get_data (Frame.get frame field) in
                Video.Canvas.iter Image.YUV420.randomize data 0 video_len;
                Frame.set frame field (Content.Video.lift_data ~length data)
            | _ -> failwith "Invalid content type!")
        self#content_type
        (Frame.create ~length self#content_type)
  end

let _ =
  let return_t = Lang.internal_tracks_t () in
  Lang.add_operator "noise" ~category:`Input
    ~descr:"Generate audio/video noise source."
    [
      ( "duration",
        Lang.nullable_t Lang.float_t,
        Some Lang.null,
        Some "Duration in seconds (`null` means infinite)." );
    ]
    ~return_t
    (fun p ->
      new noise (Lang.to_valued_option Lang.to_float (List.assoc "duration" p)))
