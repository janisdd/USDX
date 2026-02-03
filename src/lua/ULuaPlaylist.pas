{* UltraStar Deluxe - Karaoke Game
 *
 * UltraStar Deluxe is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING. If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *
 * $URL$
 * $Id$
 *}

unit ULuaPlaylist;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  ULua;

{ Playlist.GetPlaylists - no arguments
  returns array of playlists with fields:
    Name: string
    Filename: string (UTF-8)
    Items: array of { SongID: integer, Artist: string, Title: string 
  note: SongID is the internal 0-based song index }
function ULuaPlaylist_GetPlaylists(L: Plua_State): Integer; cdecl;

{ Playlist.GetPlaylist(Index: integer) - returns playlist table or nil }
function ULuaPlaylist_GetPlaylist(L: Plua_State): Integer; cdecl;

{ Playlist.GetCurrent - returns current playlist index (1-based) or nil }
function ULuaPlaylist_GetCurrent(L: Plua_State): Integer; cdecl;

{ Playlist.Set(Index: integer, SongID: integer=nil) - activates playlist
  returns true on success }
function ULuaPlaylist_Set(L: Plua_State): Integer; cdecl;

{ Playlist.Unset - clears current playlist selection }
function ULuaPlaylist_Unset(L: Plua_State): Integer; cdecl;

{ Playlist.Add(Name: string) - creates playlist and returns index (1-based) }
function ULuaPlaylist_Add(L: Plua_State): Integer; cdecl;

{ Playlist.Delete(Index: integer) - deletes playlist, returns true on success }
function ULuaPlaylist_Delete(L: Plua_State): Integer; cdecl;

{ Playlist.AddItem(SongID: integer, PlaylistIndex: integer=nil) - returns true on success }
function ULuaPlaylist_AddItem(L: Plua_State): Integer; cdecl;

{ Playlist.DeleteItem(ItemIndex: integer, PlaylistIndex: integer=nil) - returns true on success }
function ULuaPlaylist_DeleteItem(L: Plua_State): Integer; cdecl;

{ Playlist.Reload(Index: integer) - returns true on success }
function ULuaPlaylist_Reload(L: Plua_State): Integer; cdecl;

{ Playlist.Save(Index: integer) - returns true on success }
function ULuaPlaylist_Save(L: Plua_State): Integer; cdecl;

const
  ULuaPlaylist_Lib_f: array [0..10] of lual_reg = (
    (name:'GetPlaylists'; func:ULuaPlaylist_GetPlaylists),
    (name:'GetPlaylist'; func:ULuaPlaylist_GetPlaylist),
    (name:'GetCurrent'; func:ULuaPlaylist_GetCurrent),
    (name:'Set'; func:ULuaPlaylist_Set),
    (name:'Unset'; func:ULuaPlaylist_Unset),
    (name:'Add'; func:ULuaPlaylist_Add),
    (name:'Delete'; func:ULuaPlaylist_Delete),
    (name:'AddItem'; func:ULuaPlaylist_AddItem),
    (name:'DeleteItem'; func:ULuaPlaylist_DeleteItem),
    (name:'Reload'; func:ULuaPlaylist_Reload),
    (name:'Save'; func:ULuaPlaylist_Save)
  );

implementation

uses
  ULuaUtils,
  UPlaylist;

procedure LuaPlaylist_PushItem(L: Plua_State; const Item: TPlaylistItem);
begin
  lua_createtable(L, 0, 3);

  lua_pushInteger(L, Item.SongID);
  lua_setField(L, -2, 'SongID');

  lua_pushString(L, PChar(Item.Artist));
  lua_setField(L, -2, 'Artist');

  lua_pushString(L, PChar(Item.Title));
  lua_setField(L, -2, 'Title');
end;

procedure LuaPlaylist_PushPlaylist(L: Plua_State; const Playlist: TPlaylist);
var
  I: Integer;
begin
  lua_createtable(L, 0, 3);

  lua_pushString(L, PChar(Playlist.Name));
  lua_setField(L, -2, 'Name');

  lua_pushString(L, PChar(Playlist.Filename.ToUTF8));
  lua_setField(L, -2, 'Filename');

  lua_createtable(L, Length(Playlist.Items), 0);
  for I := 0 to High(Playlist.Items) do
  begin
    lua_pushInteger(L, I + 1);
    LuaPlaylist_PushItem(L, Playlist.Items[I]);
    lua_setTable(L, -3);
  end;
  lua_setField(L, -2, 'Items');
end;

function LuaPlaylist_LuaToIndex(L: Plua_State; Arg: Integer): Integer;
begin
  Result := luaL_checkInteger(L, Arg) - 1;
end;

function LuaPlaylist_GetOptionalIndex(L: Plua_State; Arg: Integer): Integer;
begin
  if (lua_gettop(L) >= Arg) and (not lua_isnil(L, Arg)) then
    Result := LuaPlaylist_LuaToIndex(L, Arg)
  else
    Result := -1;
end;

function LuaPlaylist_ValidIndex(Index: Integer): Boolean;
begin
  Result := (Index >= 0) and (Index <= High(PlayListMan.Playlists));
end;

function ULuaPlaylist_GetPlaylists(L: Plua_State): Integer; cdecl;
var
  I: Integer;
begin
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushNil(L);
    Result := 1;
    Exit;
  end;

  lua_clearStack(L);
  lua_createtable(L, Length(PlayListMan.Playlists), 0);
  for I := 0 to High(PlayListMan.Playlists) do
  begin
    lua_pushInteger(L, I + 1);
    LuaPlaylist_PushPlaylist(L, PlayListMan.Playlists[I]);
    lua_setTable(L, -3);
  end;
  Result := 1;
end;

function ULuaPlaylist_GetPlaylist(L: Plua_State): Integer; cdecl;
var
  Index: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushNil(L);
    Exit;
  end;

  Index := LuaPlaylist_LuaToIndex(L, 1);
  if not LuaPlaylist_ValidIndex(Index) then
  begin
    lua_clearStack(L);
    lua_pushNil(L);
    Exit;
  end;

  lua_clearStack(L);
  LuaPlaylist_PushPlaylist(L, PlayListMan.Playlists[Index]);
end;

function ULuaPlaylist_GetCurrent(L: Plua_State): Integer; cdecl;
begin
  lua_clearStack(L);
  if (PlayListMan = nil) or (PlayListMan.CurPlayList < 0) then
    lua_pushNil(L)
  else
    lua_pushInteger(L, PlayListMan.CurPlayList + 1);
  Result := 1;
end;

function ULuaPlaylist_Set(L: Plua_State): Integer; cdecl;
var
  Index: Integer;
  SongID: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  Index := LuaPlaylist_LuaToIndex(L, 1);
  if not LuaPlaylist_ValidIndex(Index) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  if (lua_gettop(L) >= 2) and (not lua_isnil(L, 2)) then
    SongID := luaL_checkInteger(L, 2)
  else
    SongID := -1;

  PlayListMan.SetPlayList(Index, SongID);
  lua_clearStack(L);
  lua_pushBoolean(L, True);
end;

function ULuaPlaylist_Unset(L: Plua_State): Integer; cdecl;
begin
  Result := 0;
  if (PlayListMan <> nil) then
    PlayListMan.UnsetPlaylist;
  lua_clearStack(L);
end;

function ULuaPlaylist_Add(L: Plua_State): Integer; cdecl;
var
  Name: UTF8String;
  Index: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushNil(L);
    Exit;
  end;

  Name := luaL_checkString(L, 1);
  Index := PlayListMan.AddPlaylist(Name);
  lua_clearStack(L);
  lua_pushInteger(L, Index + 1);
end;

function ULuaPlaylist_Delete(L: Plua_State): Integer; cdecl;
var
  Index: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  Index := LuaPlaylist_LuaToIndex(L, 1);
  if not LuaPlaylist_ValidIndex(Index) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  PlayListMan.DelPlaylist(Index);
  lua_clearStack(L);
  lua_pushBoolean(L, True);
end;

function ULuaPlaylist_AddItem(L: Plua_State): Integer; cdecl;
var
  SongID: Integer;
  PlaylistIndex: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  SongID := luaL_checkInteger(L, 1);
  PlaylistIndex := LuaPlaylist_GetOptionalIndex(L, 2);

  if (PlaylistIndex = -1) then
  begin
    if (PlayListMan.CurPlayList < 0) then
    begin
      lua_clearStack(L);
      lua_pushBoolean(L, False);
      Exit;
    end;
  end
  else if not LuaPlaylist_ValidIndex(PlaylistIndex) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  PlayListMan.AddItem(SongID, PlaylistIndex);
  lua_clearStack(L);
  lua_pushBoolean(L, True);
end;

function ULuaPlaylist_DeleteItem(L: Plua_State): Integer; cdecl;
var
  ItemIndex: Integer;
  PlaylistIndex: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  ItemIndex := LuaPlaylist_LuaToIndex(L, 1);
  PlaylistIndex := LuaPlaylist_GetOptionalIndex(L, 2);

  if (ItemIndex < 0) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  if (PlaylistIndex = -1) then
  begin
    if (PlayListMan.CurPlayList < 0) then
    begin
      lua_clearStack(L);
      lua_pushBoolean(L, False);
      Exit;
    end;
  end
  else if not LuaPlaylist_ValidIndex(PlaylistIndex) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  PlayListMan.DelItem(ItemIndex, PlaylistIndex);
  lua_clearStack(L);
  lua_pushBoolean(L, True);
end;

function ULuaPlaylist_Reload(L: Plua_State): Integer; cdecl;
var
  Index: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  Index := LuaPlaylist_LuaToIndex(L, 1);
  if not LuaPlaylist_ValidIndex(Index) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  lua_clearStack(L);
  lua_pushBoolean(L, PlayListMan.ReloadPlayList(Index));
end;

function ULuaPlaylist_Save(L: Plua_State): Integer; cdecl;
var
  Index: Integer;
begin
  Result := 1;
  if (PlayListMan = nil) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  Index := LuaPlaylist_LuaToIndex(L, 1);
  if not LuaPlaylist_ValidIndex(Index) then
  begin
    lua_clearStack(L);
    lua_pushBoolean(L, False);
    Exit;
  end;

  PlayListMan.SavePlayList(Index);
  lua_clearStack(L);
  lua_pushBoolean(L, True);
end;

end.
