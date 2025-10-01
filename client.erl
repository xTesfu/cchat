-module(client).
-export([handle/2, initial_state/3]).

% This record defines the structure of the state of a client.
% Add whatever other fields you need.
-record(client_st, {
    gui, % atom of the GUI process
    nick, % nick/username of the client
    server, % atom of the chat server
    client_id, % unique id of the client
    joined_channels % map of joined channels
}).

% Function to generate unique client ID
generate_client_id() ->
    {MegaSecs, Secs, _} = erlang:timestamp(),
    Combined = MegaSecs * 5000 + Secs div 5000,
    Random = rand:uniform(62418162309871246125),
    Unique = (Combined bsl 19) bor Random,
    integer_to_list(Unique).

% Return an initial state record. This is called from GUI.
% Do not change the signature of this function.
initial_state(Nick, GUIAtom, ServerAtom) ->
    #client_st{
        gui = GUIAtom,
        nick = Nick,
        server = ServerAtom,
        client_id = generate_client_id(),
        joined_channels = #{}
    }.

% handle/2 handles each kind of request from GUI
% Parameters:
%   - the current state of the client (St)
%   - request data from GUI
% Must return a tuple {reply, Data, NewState}, where:
%   - Data is what is sent to GUI, either the atom `ok` or a tuple {error, Atom, "Error message"}
%   - NewState is the updated state of the client

% Join channel
handle(St = #client_st{server = Server, client_id = Client_Id, joined_channels = Joined_Channels}, {join, Channel}) ->
    ServerPid = erlang:whereis(Server),
    case ServerPid == undefined of
        false ->
            case catch genserver:request(ServerPid, {join, Client_Id, Channel, self()}, 2000) of
                {ok, ChannelRef} -> 
                    {reply, ok, St#client_st{joined_channels = maps:put(Channel, ChannelRef, Joined_Channels)}};
                timeout_error -> 
                    {reply, {error, server_not_reached, "Server is non-responsive. Failed to join channel"}, St};
                already_joined -> 
                    {reply, {error, user_already_joined, "User already joined channel: "++Channel++". Failed to join channel"}, St};
                {error, Reason} -> 
                    {reply, {error, Reason, "Failed to join channel"}, St}
            end;
        true -> 
            {reply, {error, server_not_reached, "Server cannot be reached. Failed to join channel: "++Channel}, St}
    end;

% Leave channel
handle(St = #client_st{server = Server, client_id = Client_Id}, {leave, Channel}) ->
    ServerPid = erlang:whereis(Server),
    case ServerPid == undefined of
        true -> 
            {reply, ok, St};
        false ->
            case catch genserver:request(Server, {leave, Client_Id, Channel}) of
                ok -> 
                    {reply, ok, St};
                timeout_error -> 
                    {reply, {error, server_not_reached, "Server is non-responsive. Failed to leave channel: "++Channel}, St};
                user_not_joined -> 
                    {reply, {error, user_not_joined, "User has not joined channel. Failed to leave channel: "++Channel}, St};
                {error, Reason} -> 
                    {reply, {error, Reason, "Failed to leave channel"}, St}
            end
    end;

% Sending message (from GUI, to channel)
handle(St = #client_st{server = Server, nick = Nick, client_id = Client_Id, joined_channels = Joined_Channels}, {message_send, Channel, Msg}) ->
    HasJoinedChannel = maps:is_key(Channel, Joined_Channels),
    case HasJoinedChannel of
        true ->
            ChannelPID = erlang:whereis(list_to_atom(Channel)),
            case ChannelPID == undefined of
                true -> 
                    {reply, {error, server_not_reached, "Server cannot be reached. Failed to send message from user: "++erlang:pid_to_list(self())++" to channel: "++Channel}, St};
                false ->
                    ChannelRef = maps:get(Channel, Joined_Channels),
                    case genserver:request(ChannelRef, {message_send, Nick, Msg, Client_Id}) of
                        user_not_joined -> 
                            {reply, {error, user_not_joined, "User has not joined channel. Failed to send message to channel: "++Channel}, St};
                        {error, Reason} -> 
                            {reply, {error, Reason, "Failed to send message"}, St};
                        ok -> 
                            {reply, ok, St}
                    end
            end;
        false ->
            case genserver:request(Server, {doesChannelExist, Channel}) of
                channel_doesnt_exist -> 
                    {reply, {error, server_not_reached, "Server cannot be reached. Failed to send message because channel: "++Channel++" does not exist"}, St};
                {error, _} -> 
                    {reply, {error, user_not_joined, "User has not joined channel. Failed to send message from user: "++erlang:pid_to_list(self())++" to channel: "++Channel}, St};
                _ -> 
                    {reply, {error, user_not_joined, "User has not joined channel. Failed to send message from user: "++erlang:pid_to_list(self())++" to channel: "++Channel++" because channel does not exist"}, St}
            end
    end;

% Change nick (no check, local only)
handle(St, {nick, NewNick}) ->
    {reply, ok, St#client_st{nick = NewNick}};

% Get current nick
handle(St, whoami) ->
    {reply, St#client_st.nick, St};

% Incoming message (from channel, to GUI)
handle(St = #client_st{gui = GUI}, {message_receive, Channel, Nick, Msg}) ->
    gen_server:call(GUI, {message_receive, Channel, Nick++"> "++Msg}),
    {reply, ok, St};

% Quit client via GUI
handle(St, quit) ->
    {reply, ok, St};

% Catch-all for any unhandled requests
handle(St, _) ->
    {reply, {error, not_implemented, "Client does not handle this command"}, St}.