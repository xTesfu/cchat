-module(server).
-export([start/1, stop/1]).

%%====================================================================
%% Server API
%%====================================================================

%---------------------------------------------------------------------
% start/1
%
% Start a new server process.
% - ServerAtom: atom name to register the server under.
% - Initializes the server state with:
%     "channels" => #{}, "nicks" => #{}.
% - Spawns a genserver process that handles requests via handle_request/2.
% - Registers the process under ServerAtom.
% - Returns the process PID.
%---------------------------------------------------------------------
start(ServerAtom) ->
    Callback = fun handle_request/2,
    InitialState = #{"channels" => #{}, "nicks" => #{}},
    case whereis(ServerAtom) of
        undefined -> genserver:start(ServerAtom, InitialState, Callback);
        Pid -> Pid
    end.

%---------------------------------------------------------------------
% stop/1
%
% Stop the server process registered under ServerName.
% - Looks up the registered process.
% - If found:
%     1. Sends a stop request to the server.
%     2. Stops all channel processes.
% - Always returns ok.
%---------------------------------------------------------------------
stop(ServerName) ->
    case whereis(ServerName) of
        undefined -> ok;
        _Pid ->
            catch genserver:request(ServerName, stop),
            genserver:stop(ServerName),
            ok
    end.

%%====================================================================
%% Request Handling (Server Loop)
%%====================================================================

%---------------------------------------------------------------------
% handle_request/2 - {join, ClientId, Nick, Channel, Pid}
%
% Handle client join request.
% - Ensures the channel exists (creates if needed).
% - Forwards the join request to the channel process.
% - If successful, updates nick table in the server state.
%---------------------------------------------------------------------
handle_request(State, {join, ClientId, Nick, Channel, Pid}) ->
    Channels = maps:get("channels", State, #{}),
    Updated = ensure_channel(Channel, Channels),
    NewState = State#{"channels" => Updated},
    ChanPid = maps:get(Channel, Updated),
    case catch genserver:request(ChanPid, {join, ClientId, Pid}) of
        ok ->
            NickTable = maps:get("nicks", NewState, #{}),
            UpdatedNickTable = maps:put(Nick, true, NickTable),
            NewState2 = NewState#{"nicks" => UpdatedNickTable},
            {reply, {ok, ChanPid}, NewState2};
        already_joined -> {reply, already_joined, State};
        timeout_error  -> {reply, error, State};
        _              -> {reply, error, State}
    end;

%---------------------------------------------------------------------
% handle_request/2 - {leave, ClientId, Channel}
%
% Handle client leave request.
% - Verifies the channel exists.
% - Forwards the leave request to the channel process.
% - Returns appropriate response (ok, user_not_joined, etc.).
%---------------------------------------------------------------------
handle_request(State, {leave, ClientId, Channel}) ->
    Channels = maps:get("channels", State, #{}),
    case maps:is_key(Channel, Channels) of
        true ->
            ChanPid = maps:get(Channel, Channels),
            case catch genserver:request(ChanPid, {leave, ClientId}) of
                ok              -> {reply, ok, State};
                user_not_joined -> {reply, user_not_joined, State};
                timeout_error   -> {reply, error, State};
                _               -> {reply, error, State}
            end;
        false -> {reply, server_not_reached, State}
    end;

%---------------------------------------------------------------------
% handle_request/2 - {change_nick, OldNick, NewNick}
%
% Handle nickname change request.
% - Replaces OldNick with NewNick if available.
% - Updates the nick table in the server state.
%---------------------------------------------------------------------
handle_request(State, {change_nick, OldNick, NewNick}) ->
    NickTable = maps:get("nicks", State, #{}),
    case maps:is_key(NewNick, NickTable) of
        false ->
            Tmp = maps:remove(OldNick, NickTable),
            Updated = maps:put(NewNick, true, Tmp),
            {reply, ok, State#{"nicks" => Updated}};
        true -> {reply, nick_taken, State}
    end;

%---------------------------------------------------------------------
% handle_request/2 - {doesChannelExist, Channel}
%
% Check whether a given channel exists.
% - Looks up "channels" map from the state.
% - Replies with:
%     ok                   if channel exists,
%     channel_doesnt_exist if not.
%---------------------------------------------------------------------
handle_request(State, {doesChannelExist, Channel}) ->
    Channels = maps:get("channels", State, #{}),
    case maps:is_key(Channel, Channels) of
        true  -> {reply, ok, State};
        false -> {reply, channel_doesnt_exist, State}
    end;

%---------------------------------------------------------------------
% handle_request/2 - stop
%
% Handle server stop request.
% - Stops all active channel processes.
% - Clears channels and nick tables for a clean shutdown.
%---------------------------------------------------------------------
handle_request(State, stop) ->
    maps:foreach(fun(_, Pid) -> genserver:stop(Pid) end,
                 maps:get("channels", State, #{})),
    ClearedState = #{"channels" => #{}, "nicks" => #{}},
    {reply, ok, ClearedState};

%---------------------------------------------------------------------
% handle_request/2 - Unknown
%
% Default clause for unknown requests.
% - Returns an error tuple without altering the state.
%---------------------------------------------------------------------
handle_request(State, _Other) ->
    {reply, {error, unknown_request}, State}.

%%====================================================================
%% Channel Management
%%====================================================================

%---------------------------------------------------------------------
% ensure_channel/2
%
% Ensure a channel exists in the channels map.
% - If found: returns channels unchanged.
% - If not found: starts a new channel process and inserts it.
%---------------------------------------------------------------------
ensure_channel(Name, Channels) ->
    case maps:is_key(Name, Channels) of
        true  -> Channels;
        false -> Channels#{Name => start_channel(Name)}
    end.

%---------------------------------------------------------------------
% start_channel/1
%
% Start a new channel process.
% - Registers channel using its name as an atom.
% - Initializes state with:
%     "users" => #{}, "name" => Name.
% - Uses channel_handler/2 for message handling.
%---------------------------------------------------------------------
start_channel(Name) ->
    Fun = fun channel_handler/2,
    genserver:start(list_to_atom(Name),
                    #{"users" => #{}, "name" => Name},
                    Fun).

%%====================================================================
%% Channel Request Handling
%%====================================================================

%---------------------------------------------------------------------
% channel_handler/2 - {join, ClientId, Pid}
%
% Handle client join within a channel.
% - Adds the client to the user map if not already joined.
%---------------------------------------------------------------------
channel_handler(State, {join, ClientId, Pid}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(ClientId, Users) of
        false ->
            NewUsers = Users#{ClientId => Pid},
            {reply, ok, State#{"users" => NewUsers}};
        true ->
            {reply, already_joined, State}
    end;

%---------------------------------------------------------------------
% channel_handler/2 - {leave, ClientId}
%
% Handle client leave within a channel.
% - Removes the client if present.
% - Returns ok or user_not_joined.
%---------------------------------------------------------------------
channel_handler(State, {leave, ClientId}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(ClientId, Users) of
        true  -> {reply, ok, State#{"users" => maps:remove(ClientId, Users)}};
        false -> {reply, user_not_joined, State}
    end;

%---------------------------------------------------------------------
% channel_handler/2 - {message_send, Nick, Msg, SenderId}
%
% Handle message broadcasting within a channel.
% - Sends the message to all users except the sender.
%---------------------------------------------------------------------
channel_handler(State, {message_send, Nick, Msg, SenderId}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(SenderId, Users) of
        true ->
            ChanName = maps:get("name", State),
            maps:foreach(
                fun(Id, P) ->
                    if Id =/= SenderId ->
                        send_message(ChanName, Nick, Msg, P);
                       true -> ok
                    end
                end,
                Users),
            {reply, ok, State};
        false ->
            {reply, user_not_joined, State}
    end;

%---------------------------------------------------------------------
% channel_handler/2 - Unknown
%
% Handle unknown channel-level requests.
%---------------------------------------------------------------------
channel_handler(State, _) ->
    {reply, {error, unknown_request}, State}.

%%====================================================================
%% Messaging Utilities
%%====================================================================

%---------------------------------------------------------------------
% send_message/4
%
% Send a message to a client process.
% - Wraps message in {request, ...} tuple.
% - Includes channel name, sender nickname, and message text.
%---------------------------------------------------------------------
send_message(Channel, Nick, Msg, Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, {message_receive, Channel, Nick, Msg}}.