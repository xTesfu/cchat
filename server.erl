-module(server).
-export([start/1, stop/1]).

%%====================================================================
%% Server API
%%====================================================================

% Start a new server process.
% - ServerAtom: the atom name under which to register the server
% - Creates initial state (empty channel map and nickname table)
% - Spawns a process that waits for messages, handles them with handle_request/2, and loops
% - Registers the process under ServerAtom
% - Returns the process PID
start(ServerAtom) ->
    Callback = fun handle_request/2,
    InitialState = #{"channels" => #{}, "nicks" => #{}},
    case whereis(ServerAtom) of
        undefined -> genserver:start(ServerAtom, InitialState, Callback);
        Pid -> Pid
    end.

% Stop the server process registered under ServerName.
% - Looks up the process
% - If found:
%   1. Requests the server to stop all channel processes
%   2. Stops the server loop itself
% - Always returns ok
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

% Handle join request:
% - Ensure channel exists, creating it if necessary
% - Forward join request to channel process
% - If join successful:
%     - Update state with the new nick
handle_request(State, {join, ClientId, Nick, Channel, Pid}) ->
    Channels = maps:get("channels", State, #{}),
    Updated = ensure_channel(Channel, Channels),
    NewState = State#{"channels" => Updated},
    ChanPid = maps:get(Channel, Updated),
    case catch genserver:request(ChanPid, {join, ClientId, Pid}) of
        ok -> 
            % Add the new nick to the nick table in the state
            NickTable = maps:get("nicks", NewState, #{}),
            UpdatedNickTable = maps:put(Nick, true, NickTable),
            NewState2 = NewState#{"nicks" => UpdatedNickTable},
            {reply, {ok, ChanPid}, NewState2};
        already_joined  -> {reply, already_joined, State};
        timeout_error   -> {reply, error, State};
        _               -> {reply, error, State}
    end;

% Handle leave request:
% - Check if channel exists
% - Forward leave request to channel process
% - Return appropriate response
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

% Handle nickname change:
% - Replace OldNick with NewNick if not already taken
% - Update nickname table in state
handle_request(State, {change_nick, OldNick, NewNick}) ->
    NickTable = maps:get("nicks", State, #{}),
    case maps:is_key(NewNick, NickTable) of
        false ->
            Tmp = maps:remove(OldNick, NickTable),
            Updated = maps:put(NewNick, true, Tmp),
            {reply, ok, State#{"nicks" => Updated}};
        true -> {reply, nick_taken, State}
    end;

% Handle channel existence check:
% - Retrieve the channels map from the state (default to empty if missing)
% - Check if the given channel exists in the map
% - Reply with:
%     ok if the channel exists
%     channel_doesnt_exist if not
handle_request(State, {doesChannelExist, Channel}) ->
    Channels = maps:get("channels", State, #{}),
    case maps:is_key(Channel, Channels) of
        true  -> {reply, ok, State};
        false -> {reply, channel_doesnt_exist, State}
    end;

% Handle stop request:
% - Stop all channel processes
% - Keep state unchanged
handle_request(State, stop) ->
    maps:foreach(fun(_, Pid) -> genserver:stop(Pid) end,
                 maps:get("channels", State, #{})),
    {reply, ok, State};

% Handle unknown requests gracefully
handle_request(State, _Other) ->
    {reply, {error, unknown_request}, State}.

%%====================================================================
%% Channel Management
%%====================================================================

% Ensure a channel exists in the channel map:
% - If found: return channels unchanged
% - If not found: start a new channel process and insert into map
ensure_channel(Name, Channels) ->
    case maps:is_key(Name, Channels) of
        true  -> Channels;
        false -> Channels#{Name => start_channel(Name)}
    end.

% Start a new channel process:
% - Registers channel with atom name
% - Initializes state with empty user map and channel name
% - Uses channel_handler/2 as callback
start_channel(Name) ->
    Fun = fun channel_handler/2,
    genserver:start(list_to_atom(Name),
                    #{"users" => #{}, "name" => Name},
                    Fun).

%%====================================================================
%% Channel Request Handling
%%====================================================================

% Handle join request in a channel:
% - Add client to user map if not already present
channel_handler(State, {join, ClientId, Pid}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(ClientId, Users) of
        false ->
            NewUsers = Users#{ClientId => Pid},
            {reply, ok, State#{"users" => NewUsers}};
        true ->
            {reply, already_joined, State}
    end;

% Handle leave request in a channel:
% - Remove client if present
channel_handler(State, {leave, ClientId}) ->
    Users = maps:get("users", State, #{}),
    case maps:is_key(ClientId, Users) of
        true  -> {reply, ok, State#{"users" => maps:remove(ClientId, Users)}};
        false -> {reply, user_not_joined, State}
    end;

% Handle message sending in a channel:
% - Broadcasts message to all users except sender
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

% Handle unknown channel requests
channel_handler(State, _) ->
    {reply, {error, unknown_request}, State}.

%%====================================================================
%% Messaging Utilities
%%====================================================================

% Send a message to a client process:
% - Wraps message in {request, ...} tuple
% - Includes channel name, nickname, and message text
send_message(Channel, Nick, Msg, Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, {message_receive, Channel, Nick, Msg}}.