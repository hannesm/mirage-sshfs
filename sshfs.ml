(*
 * Copyright (c) 2021 Pierre Alain <pierre.alain@tuta.io>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt.Infix

module Make (B: Mirage_block.S) = struct

  let log_src = Logs.Src.create "sshfs_protocol" ~doc:"Protocol dealer for sshfs"
  module Log = (val Logs.src_log log_src : Logs.LOG)

  module FS = Fat.Make(B)

  let fail fmt = Fmt.kstrf Lwt.fail_with fmt

  let (>>*=) m f = m >>= function
    | Error e -> fail "%a" FS.pp_write_error (e :> FS.write_error)
    | Ok x    -> f x

  let connect disk =
    FS.connect disk

  type sshfs_attrs =
    | SSH_FXF_READ
    | SSH_FXF_WRITE
    | SSH_FXF_APPEND
    | SSH_FXF_CREAT
    | SSH_FXF_TRUNC
    | SSH_FXF_EXCL
    | SSH_FXF_UNDEF

  let sshfs_attrs_of_uint32 = function
    | 0x00000001 -> SSH_FXF_READ
    | 0x00000002 -> SSH_FXF_WRITE
    | 0x00000004 -> SSH_FXF_APPEND
    | 0x00000008 -> SSH_FXF_CREAT
    | 0x00000010 -> SSH_FXF_TRUNC
    | 0x00000020 -> SSH_FXF_EXCL
    | _ -> SSH_FXF_UNDEF

  (*

  4bytes errcodes of message

  	#define SSH_FX_FAILURE                       4
  	#define SSH_FX_BAD_MESSAGE                   5
  	#define SSH_FX_NO_CONNECTION                 6
  	#define SSH_FX_CONNECTION_LOST               7
  	#define SSH_FX_OP_UNSUPPORTED                8

  *)
  type sshfs_errcode =
    | SSH_FX_OK
    | SSH_FX_EOF
    | SSH_FX_NO_SUCH_FILE
    | SSH_FX_PERMISSION_DENIED
    | SSH_FX_INVALID_HANDLE
    | SSH_FX_NO_SUCH_PATH
    | SSH_FX_FILE_IS_A_DIRECTORY
    | SSH_FX_OP_UNSUPPORTED

  let sshfs_errcode_to_uint32 = function
    | SSH_FX_OK -> 0l
    | SSH_FX_EOF -> 1l
    | SSH_FX_NO_SUCH_FILE -> 2l
    | SSH_FX_PERMISSION_DENIED -> 3l
    | SSH_FX_INVALID_HANDLE -> 9l
    | SSH_FX_NO_SUCH_PATH -> 10l
    | SSH_FX_FILE_IS_A_DIRECTORY -> 24l
    | SSH_FX_OP_UNSUPPORTED -> 31l

  (*1 byte type of messages
    | SSH_FXP_FSTAT               8
    | SSH_FXP_REALPATH           16
    | SSH_FXP_STAT               17
    | SSH_FXP_READLINK           19
    | SSH_FXP_LINK               21
    | SSH_FXP_BLOCK              22
    | SSH_FXP_UNBLOCK            23

    | SSH_FXP_EXTENDED          200
    | SSH_FXP_EXTENDED_REPLY    201
  *)

  type sshfs_packtype =
    | SSH_FXP_INIT
    | SSH_FXP_VERSION
    | SSH_FXP_OPEN
    | SSH_FXP_CLOSE
    | SSH_FXP_READ
    | SSH_FXP_WRITE
    | SSH_FXP_LSTAT
    | SSH_FXP_SETSTAT
    | SSH_FXP_FSETSTAT
    | SSH_FXP_OPENDIR
    | SSH_FXP_READDIR
    | SSH_FXP_REMOVE
    | SSH_FXP_MKDIR
    | SSH_FXP_RMDIR
    | SSH_FXP_RENAME
    | SSH_FXP_STATUS
    | SSH_FXP_HANDLE
    | SSH_FXP_DATA
    | SSH_FXP_NAME
    | SSH_FXP_ATTRS
    | UNDEF_SSHFS_PACKTYPE

  let sshfs_packtype_of_uint8 = function
    | 1 -> SSH_FXP_INIT
    | 2 -> SSH_FXP_VERSION
    | 3 -> SSH_FXP_OPEN
    | 4 -> SSH_FXP_CLOSE
    | 5 -> SSH_FXP_READ
    | 6 -> SSH_FXP_WRITE
    | 7 -> SSH_FXP_LSTAT
    | 9 -> SSH_FXP_SETSTAT
    | 10 -> SSH_FXP_FSETSTAT
    | 11 -> SSH_FXP_OPENDIR
    | 12 -> SSH_FXP_READDIR
    | 13 -> SSH_FXP_REMOVE
    | 14 -> SSH_FXP_MKDIR
    | 15 -> SSH_FXP_RMDIR
    | 18 -> SSH_FXP_RENAME
    | 101 -> SSH_FXP_STATUS
    | 102 -> SSH_FXP_HANDLE
    | 103 -> SSH_FXP_DATA
    | 104 -> SSH_FXP_NAME
    | 105 -> SSH_FXP_ATTRS
    | _ -> UNDEF_SSHFS_PACKTYPE

  let sshfs_packtype_to_uint8 = function
    | SSH_FXP_INIT -> 1
    | SSH_FXP_VERSION -> 2
    | SSH_FXP_OPEN -> 3
    | SSH_FXP_CLOSE -> 4
    | SSH_FXP_READ -> 5
    | SSH_FXP_WRITE -> 6
    | SSH_FXP_LSTAT -> 7
    | SSH_FXP_SETSTAT -> 9
    | SSH_FXP_FSETSTAT -> 10
    | SSH_FXP_OPENDIR -> 11
    | SSH_FXP_READDIR -> 12
    | SSH_FXP_REMOVE -> 13
    | SSH_FXP_MKDIR -> 14
    | SSH_FXP_RMDIR -> 15
    | SSH_FXP_RENAME -> 18
    | SSH_FXP_STATUS -> 101
    | SSH_FXP_HANDLE -> 102
    | SSH_FXP_DATA -> 103
    | SSH_FXP_NAME -> 104
    | SSH_FXP_ATTRS -> 105
    | _ -> 0

  let attr_is_activated a x =
    Lwt.return (a land x = a)

  let uint8_to_cs i =
    let cs = Cstruct.create 1 in
    Cstruct.set_uint8 cs 0 i;
    cs

  let uint32_to_cs i = 
    let cs = Cstruct.create 4 in
    Cstruct.BE.set_uint32 cs 0 i;
    cs

  let uint32_of_cs cs = 
    Cstruct.BE.get_uint32 cs 0

  let uint64_to_cs i = 
    let cs = Cstruct.create 8 in
    Cstruct.BE.set_uint64 cs 0 i;
    cs

  let uint64_of_cs cs = 
    Cstruct.BE.get_uint64 cs 0

  let payload_of_string s =
    Cstruct.concat [uint32_to_cs (Int32.of_int(String.length s)) ;
      Cstruct.of_string s ]

  (* sftp message is length(4 bytes) + type(1 byte) + data (length-1 bytes, starting with request-id:4 bytes) *)
  let to_client typ payload =
    Cstruct.concat [uint32_to_cs (Int32.of_int (1+(Cstruct.length payload))) ;
      uint8_to_cs (sshfs_packtype_to_uint8 typ) ;
      payload ]

  let from_client msg =
    let typ = sshfs_packtype_of_uint8 (Cstruct.get_uint8 msg 0) in
    let dat = Cstruct.sub msg 1 ((Cstruct.length msg) -1) in
    typ, dat

  let rec accessing_path path = 
    let first_slash_idx = Option.value ~default:(~-1) (String.index_from_opt path 0 '/') in
    if (first_slash_idx = ~-1) then (* no more '/' *)
      Lwt.return ("", path)
    else
      let current_dir = String.sub path 0 first_slash_idx in
      let remaining = (String.sub path (first_slash_idx+1) (String.length path - (first_slash_idx+1))) in
      accessing_path remaining >>= fun (dirlisting, last) ->
      (* WARNING: calling with a trailing / will cause last to be empty  *)
      if (String.equal last "") then
        Lwt.return (current_dir, dirlisting)
      else
        Lwt.return ((String.concat "/" [current_dir; dirlisting]), last)

  open Fat

  let file_buf root file =
    accessing_path file >>= fun (dirlisting, last) ->
    FS.listdir root dirlisting >>*= fun res ->
    if (List.mem last res) then
      FS.size root file >>*= fun (s) ->
      FS.read root file 0 (Int64.to_int s) >>*= fun(payload) -> (*TODO: avoid buffer overflow as the file is controlled by a user *)
      let payload = Cstruct.concat payload in
      Lwt.return payload
    else
(*      Log.warn (fun f -> f "*** file %s not found\n%!" file);*)
      Lwt.return (Cstruct.create 0)

  let is_present root path =
    accessing_path path >>= fun (dirlisting, last) ->
    FS.listdir root dirlisting >>*= fun res ->
    Lwt.return (List.mem last res)

  let path_to_handle _ path =
    let handle = path in
    Lwt.return handle

  let path_of_handle _ handle =
    let path = handle in
    Lwt.return path

  let reply_handle root path =
    path_to_handle root path >>= fun (handle) ->
    Lwt.return (handle, SSH_FXP_HANDLE, payload_of_string handle)

  (* permissions:
   * p:4096, d:16384, -:32768
   * 256+128+64 : rwx for user
   * 32+16+8 : rwx for group
   * 4+2+1 : rws for others
   *)
  let permission root path =
    accessing_path path >>= fun (dirlisting, last) ->

    if (String.equal path "/") then
      let payload = Cstruct.concat [
      uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
      uint64_to_cs 0L ; (* size value *)
      uint32_to_cs (Int32.of_int(16384+448+56+7)) ; (* perm: drwxrwxrwx *)] in
      Lwt.return (SSH_FXP_ATTRS, payload)

    else (* path exists ?*)
      FS.listdir root dirlisting >>*= fun res ->

      if (List.mem last res) then
        FS.stat root path >>*= function
          | { directory = true; size=s; read_only=_; _ } -> (* FIXME: ro information is not used *)
            let payload = Cstruct.concat [
            uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
            uint64_to_cs s ; (* size value *)
            uint32_to_cs (Int32.of_int(16384+448+56+7)) (* perm: drwxrwxrwx *)] in
            Lwt.return (SSH_FXP_ATTRS, payload)
          | { directory = false; size=s; _ } ->
            let payload = Cstruct.concat [
            uint32_to_cs 5l ; (* SSH_FILEXFER_ATTR_SIZE(1) + ~SSH_FILEXFER_ATTR_UIDGID(2) + SSH_FILEXFER_ATTR_PERMISSIONS(4) + ~SSH_FILEXFER_ATTR_ACMODTIME(8) *)
            uint64_to_cs s ; (* size value *)
            uint32_to_cs (Int32.of_int(32768+448+56+7)) ; (* perm: -rwxrwxrwx *)] in
            Lwt.return (SSH_FXP_ATTRS, payload)
      else
        Lwt.return (SSH_FXP_STATUS, uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_NO_SUCH_FILE))

  let lsdir root path =
    FS.listdir root path >>*= fun res ->
    Lwt.return res

  (* version 3 used by openssh : https://filezilla-project.org/specs/draft-ietf-secsh-filexfer-02.txt *)
  let reply message sshout _ssherror working_table root () =
    let request_type, data = from_client message in
    let id = uint32_of_cs (Cstruct.sub data 0 4) in (* request-id *)
    begin match request_type with
      (* 4. Protocol Initialization *)
      | SSH_FXP_INIT -> 
        Log.debug (fun f -> f "[SSH_FXP_INIT with version %ld]\n%!" id);
        sshout (to_client SSH_FXP_VERSION (uint32_to_cs (min 3l (uint32_of_cs data)))) 
        >>= fun () -> Lwt.return working_table

      (* 6.8 Retrieving File Attributes *)
      | SSH_FXP_LSTAT ->
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_LSTAT %ld] for '%s'\n%!" id path);
        permission root path >>= fun (reply_type, payload) ->
        sshout (to_client reply_type (Cstruct.concat [ uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      (* 6.7 Scanning Directories *)
      | SSH_FXP_OPENDIR -> (* TODO: find a better way to deal with handles and file/dirnames *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        Log.debug (fun f -> f "[SSH_FXP_OPENDIR %ld] for '%s'\n%!" id path);
        begin match (Hashtbl.find_opt working_table path) with
        | None -> (* if the handle is not already opened -> open it and add content of this directory into the working table *)
          reply_handle root path >>= fun (handle, reply_type, payload) ->
          Log.debug (fun f -> f "[SSH_FXP_OPENDIR %ld] handle is '%s'\n%!" id handle);
          sshout (to_client reply_type (Cstruct.concat [ uint32_to_cs id ; payload ]) )
          >>= fun () -> begin
            lsdir root path >>= fun(content_list) ->
            Hashtbl.add working_table handle content_list ; Lwt.return working_table
          end
        | _ -> (* if the handle is already opened -> error *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table
        end

      | SSH_FXP_READDIR -> (* TODO: remove the ugly long-name constant... *)
        let handle_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        Log.debug (fun f -> f "[SSH_FXP_READDIR %ld] for '%s'\n%!" id handle);
        begin match (Hashtbl.find_opt working_table handle) with
        | None -> (* if the handle is not already opened -> error *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table
        | remaining_list -> (* if the handle is already opened -> reply to the client or EOF *)
          let remaining_list = Option.get remaining_list in
          if (List.length remaining_list == 0) then
            let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_EOF) in
            sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
            >>= fun () -> Lwt.return working_table
          else
            let head = List.hd remaining_list in
            path_of_handle root handle >>= fun(path) ->
            let dirname = match path with
              | "/" -> head
              | _ -> String.concat "/" [ path; head]
            in
            permission root dirname >>= fun (_, stats) ->
            let payload = Cstruct.concat [ uint32_to_cs 1l ; (* count the number of names returned *)
              payload_of_string head ; (* short-name *)
              payload_of_string "1234567890123123456781234567812345678123456789012" ; (* long-name *)
              stats ] in
            sshout (to_client SSH_FXP_NAME (Cstruct.concat [ uint32_to_cs id ; payload ]) )
            >>= fun () -> begin Hashtbl.replace working_table handle (List.tl remaining_list) ; Lwt.return working_table end
        end

      | SSH_FXP_OPEN -> (* TODO: read pflags & attrs for file creation *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        let _ (*pflags*) = uint32_of_cs (Cstruct.sub data (path_length+4) 4) in
        (* ATTRS         attrs *)
        Log.debug (fun f -> f "[SSH_FXP_OPEN %ld] for '%s'\n%!" id path);
        begin match (Hashtbl.find_opt working_table path) with
        | None -> (* if the handle is not already opened -> open it and add content of this directory into the working table *)
          reply_handle root path >>= fun (handle, reply_type, payload) ->
          sshout (to_client reply_type (Cstruct.concat [ uint32_to_cs id ; payload ]) )
          >>= fun () -> begin Hashtbl.add working_table handle [] ; Lwt.return working_table end
        | _ -> (* if the handle is already opened -> error *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table
        end

      | SSH_FXP_READ -> (* TODO: check for reading >4k files *)
        let handle_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        let offset = uint64_of_cs (Cstruct.sub data (8+handle_length) 8) in
        let len = uint32_of_cs (Cstruct.sub data (8+handle_length+8) 4) in
        path_of_handle root handle >>= fun(path) ->
        Log.debug (fun f -> f "[SSH_FXP_READ %ld] for '%s' @%Ld (%ld)\n%!" id path offset len);
        FS.size root path >>*= fun (s) ->
        if offset <= s then
          FS.read root path (Int64.to_int offset) (Int32.to_int len) >>*= fun(payload) ->
          let payload = Cstruct.concat payload in
          sshout (to_client SSH_FXP_DATA (Cstruct.concat [uint32_to_cs id ;
              uint32_to_cs (Int32.of_int(Cstruct.length payload));
              payload ])
          )
          >>= fun () -> Lwt.return working_table
        else
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_EOF) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table

      | SSH_FXP_CLOSE ->
        let handle_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        Log.debug (fun f -> f "[SSH_FXP_CLOSE %ld] for %s\n%!" id handle);
        begin match (Hashtbl.find_opt working_table handle) with
        | None -> (* if the handle is not already opened -> error *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table
        | _ -> (* if the handle is already opened -> remove the handle entry in the hash table *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> begin Hashtbl.remove working_table handle ; Lwt.return working_table end
        end

      | SSH_FXP_RMDIR (* TODO: check for the result & reply error when dir is not empty... *)
      | SSH_FXP_REMOVE -> (* TODO: check for the result *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        FS.destroy root path >>*= fun() ->
        Log.debug (fun f -> f "[SSH_FXP_REMOVE %ld] for %s\n%!" id path);
        (* FIXME: we always reply with status ok... *)
        let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
        sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      | SSH_FXP_RENAME -> (* TODO: check if file already exists *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        let newpath_length = Int32.to_int (uint32_of_cs (Cstruct.sub data (8+path_length) 4)) in
        let newpath = Cstruct.to_string (Cstruct.sub data (8+path_length+4) newpath_length) in
        Log.debug (fun f -> f "[SSH_FXP_RENAME %ld] for %s->%s\n%!" id path newpath);
        (* FIXME: ocaml-fat does not have rename function :( *)
        FS.size root path >>*= fun(s) ->
        FS.read root path 0 (Int64.to_int s) >>*= fun(data) ->
        let data = Cstruct.concat data in
        FS.create root newpath >>*= fun () ->
        FS.write root newpath 0 data >>*= fun () ->
        let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
        sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      | SSH_FXP_MKDIR-> (* TODO: check for the result *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        FS.mkdir root path >>*= fun() ->
        Log.debug (fun f -> f "[SSH_FXP_MKDIR %ld] for %s\n%!" id path);
        (* FIXME: we always reply with status ok... *)
        let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
        sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      | SSH_FXP_SETSTAT-> (* TODO: ex: touch, for now fat 16 does not do much with this kind of informations *)
        let path_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let path = Cstruct.to_string (Cstruct.sub data 8 path_length) in
        (* let attrs = ??? *)
        Log.debug (fun f -> f "[SSH_FXP_SETSTAT %ld] for %s\n%!" id path);
        (* FIXME: we always reply with status ok... *)
        let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
        sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      | SSH_FXP_FSETSTAT-> (* TODO: ex: touch, for now fat 16 does not do much with this kind of informations *)
        let handle_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        (* let attrs = ??? *)
        Log.debug (fun f -> f "[SSH_FXP_FSETSTAT %ld] for %s\n%!" id handle);
        begin match (Hashtbl.find_opt working_table handle) with
        | None -> (* if the handle is not already opened -> error *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_INVALID_HANDLE) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> Lwt.return working_table
        | _ -> (* if the handle is already opened -> remove the handle entry in the hash table *)
          let _ = path_of_handle root handle in
          (* FIXME: we always reply with status ok... *)
          let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
          sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
          >>= fun () -> begin Hashtbl.remove working_table handle ; Lwt.return working_table end
        end

      | SSH_FXP_WRITE-> (* TODO:  *)
        let handle_length = Int32.to_int (uint32_of_cs (Cstruct.sub data 4 4)) in
        let handle = Cstruct.to_string (Cstruct.sub data 8 handle_length) in
        let offset = uint64_of_cs (Cstruct.sub data (8+handle_length) 8) in
        let newdata_length = Int32.to_int (uint32_of_cs (Cstruct.sub data (8+handle_length+8) 4)) in
        let newdata = Cstruct.sub data (8+handle_length+8+4) newdata_length in
        path_of_handle root handle >>= fun(path) ->
        Log.debug (fun f -> f "[SSH_FXP_WRITE %ld] for %s\n%!" id path);
        (* FIXME: we always reply with status ok... *)
        FS.write root path (Int64.to_int offset) newdata >>*= fun () ->
        let payload = uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OK) in
        sshout (to_client SSH_FXP_STATUS (Cstruct.concat [uint32_to_cs id ; payload ]) )
        >>= fun () -> Lwt.return working_table

      | _ ->
        Log.debug (fun f -> f "[UNKNOWN %ld]\n%!" id);
        Cstruct.hexdump message ;
        let payload = Cstruct.concat [uint32_to_cs id ;
          uint32_to_cs (sshfs_errcode_to_uint32 SSH_FX_OP_UNSUPPORTED) ] in
        sshout (to_client SSH_FXP_STATUS payload);
        >>= fun () -> Lwt.return working_table
  end

end