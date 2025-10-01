-module(server).
-export([start/1, stop/1]).

% Start a new server process with the given name
% Do not change the signature of this function.
start(ServerAtom) ->
    Handlers = fun
        (State, {join, Client_Id, Channel, Pid}) ->
            Channels = maps:get("channels", State, #{}),
            NewChannels = addNewChannel(Channel, Channels),
            NewState = State#{"channels" => NewChannels},
            case catch genserver:request(maps:get(Channel, NewChannels), {join, Client_Id, Pid}) of
                ok -> {reply, {ok, maps:get(Channel, NewChannels)}, NewState};
                already_joined -> {reply, already_joined, State};
                timeout_error -> {reply, error, State};
                _ -> {reply, error, State}
            end;
        (State, {leave, Client_Id, Channel}) ->
            Current_Channels = maps:get("channels", State, #{}),
            ChannelExists = maps:is_key(Channel, Current_Channels),
            case ChannelExists of
                true ->
                    case catch genserver:request(maps:get(Channel, Current_Channels), {leave, Client_Id}) of
                        ok -> {reply, ok, State};
                        user_not_joined -> {reply, user_not_joined, State};
                        timeout_error -> {reply, error, State};
                        _ -> {reply, error, State}
                    end;
                false -> {reply, server_not_reached, State}
            end;
        (State, {change_nick, Current_Nick, New_Nick}) ->
            CurrentNicks = maps:get("currentNicks", State, #{}),
            IsNewNickUsed = maps:is_key(New_Nick, CurrentNicks),
            case IsNewNickUsed of
                false ->
                    New_Nicks = maps:put(New_Nick, true, maps:remove(Current_Nick, CurrentNicks)),
                    NewState = maps:put("currentNicks", New_Nicks, State),
                    {reply, ok, NewState};
                true -> {reply, nick_taken, State}
            end;
        (State, {doesChannelExist, Channel}) ->
            Channels = maps:get("channels", State, #{}),
            ChannelExists = maps:is_key(Channel, Channels),
            case ChannelExists of
                true -> {reply, ok, State};
                false -> {reply, channel_doesnt_exist, State}
            end;
        (State, {stop}) ->
            maps:foreach(fun(_, Pid) -> genserver:stop(Pid) end, maps:get("channels", State, #{})),
            {reply, ok, State};
        (State, _Request) -> 
            {reply, {error, unknown_request}, State}
    end,
    case erlang:whereis(ServerAtom) of
        undefined -> genserver:start(ServerAtom, #{ "channels" => #{}, "currentNicks" => #{} }, Handlers);
        ExistingPid -> ExistingPid
    end.

% Stop the server process registered to the given name,
% together with any other associated processes
stop(ServerAtom) ->
    ServerPid = erlang:whereis(ServerAtom),
    ServerExists = ServerPid /= undefined,
    case ServerExists of
        true -> 
            catch genserver:request(ServerAtom, {stop}),
            genserver:stop(ServerAtom),
            ok;
        false -> ok
    end.

% Add New Channel
addNewChannel(Channel, Channels) ->
    Channel_Exists = maps:is_key(Channel, Channels),
    case Channel_Exists of 
        true -> Channels;
        false -> Channels#{Channel => startChannel(Channel)}
    end.

% Start New Channel
startChannel(Channel) ->
    F = fun
        (State, {join, Client_Id, Pid}) ->
            CurrentUsers = maps:get("CurrentUsers", State, #{}),
            UserIsInChannel = maps:is_key(Client_Id, CurrentUsers),
            case UserIsInChannel of
                false ->
                    NewUsers = CurrentUsers#{Client_Id => Pid},
                    NewState = State#{"CurrentUsers" => NewUsers},
                    {reply, ok, NewState};
                true -> {reply, already_joined, State}
            end;
        (State, {leave, Client_Id}) ->
            CurrentUsers = maps:get("CurrentUsers", State, #{}),
            UserIsInChannel = maps:is_key(Client_Id, CurrentUsers),
            case UserIsInChannel of
                true ->
                    NewState = State#{"CurrentUsers" => maps:remove(Client_Id, CurrentUsers)},
                    {reply, ok, NewState};
                false -> {reply, user_not_joined, State}
            end;
        (State, {message_send, Nick, Message, Client_Id}) ->
            CurrentUsers = maps:get("CurrentUsers", State, #{}),
            UserIsInChannel = maps:is_key(Client_Id, CurrentUsers),
            case UserIsInChannel of 
                true ->
                    maps:foreach(fun(Id, P) -> if Id /= Client_Id -> send_message(Channel, Nick, Message, P); true -> ok end end, CurrentUsers),
                    {reply, ok, State};
                false -> {reply, user_not_joined, State}
            end;
        (State, _Request) -> 
            {reply, {error, unknown_request}, State}
    end,
    genserver:start(list_to_atom(Channel), #{ "CurrentUsers" => #{}, "Channel" => Channel }, F).

% Send Message Helper Function
send_message(Channel, Nick, Message, Pid) ->
    Ref = make_ref(),
    Pid ! {request, self(), Ref, {message_receive, Channel, Nick, Message}}.