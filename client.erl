-module(client).
-export([handle/2, initial_state/3]).

% -----------------------------------------------------------------------------
% Record definition for client state
% -----------------------------------------------------------------------------
% Fields:
%   gui              - atom of the GUI process
%   nick             - nickname/username of the client
%   server           - atom of the chat server
%   client_id        - unique id of the client
%   joined_channels  - map of joined channels and their PIDs
-record(client_st, {
    gui,
    nick,
    server,
    client_id,
    joined_channels
}).

% -----------------------------------------------------------------------------
% Utility function: generate unique client ID
% -----------------------------------------------------------------------------
generate_client_id() ->
    erlang:unique_integer([monotonic, positive]).

% -----------------------------------------------------------------------------
% Initial state setup
% -----------------------------------------------------------------------------
% Called from GUI to create a new client state record.
% - Nick: initial nickname
% - GUIAtom: GUI process atom
% - ServerAtom: chat server atom
% Returns: #client_st{} record
% -----------------------------------------------------------------------------
initial_state(Nick, GUIAtom, ServerAtom) ->
    #client_st{
        gui = GUIAtom,
        nick = Nick,
        server = ServerAtom,
        client_id = generate_client_id(),
        joined_channels = #{}
    }.

% -----------------------------------------------------------------------------
% handle/2
% Handles requests coming from the GUI.
% - St: current client state
% - Request: data from GUI
% Must return {reply, Data, NewState}.
% -----------------------------------------------------------------------------

%% ---------------------------------------------------------------------------
%% JOIN CHANNEL
%% ---------------------------------------------------------------------------
% Handle channel join request:
% - Verify the server process exists
% - Request to join the specified channel
% - On success: update state with the new channel reference
% - On failure: return error for timeout, already joined, or other reasons
handle(St = #client_st{server = Server, client_id = Client_Id, nick = Nick, joined_channels = Joined_Channels},
       {join, Channel}) ->
    case whereis(Server) of
        undefined ->
            {reply, {error, server_not_reached,
                     "Server cannot be reached. Failed to join channel: " ++ Channel}, St};
        ServerPid ->
            case catch genserver:request(ServerPid, {join, Client_Id, Nick, Channel, self()}, 2000) of
                {ok, ChannelRef} ->
                    {reply, ok,
                     St#client_st{joined_channels =
                                    maps:put(Channel, ChannelRef, Joined_Channels)}};
                timeout_error ->
                    {reply, {error, server_not_reached,
                             "Server is non-responsive. Failed to join channel"}, St};
                already_joined ->
                    {reply, {error, user_already_joined,
                             "User already joined channel: " ++ Channel}, St};
                {error, Reason} ->
                    {reply, {error, Reason, "Failed to join channel"}, St}
            end
    end;

%% ---------------------------------------------------------------------------
%% LEAVE CHANNEL
%% ---------------------------------------------------------------------------
% Handle leave request:
% - Check server availability
% - Request channel leave and update state if successful
handle(St = #client_st{server = Server, client_id = Client_Id, joined_channels = Joined_Channels},
       {leave, Channel}) ->
    case whereis(Server) of
        undefined ->
            {reply, ok, St};  % nothing to do if server is gone
        _ ->
            case catch genserver:request(Server, {leave, Client_Id, Channel}) of
                ok ->
                    % Remove channel from joined_channels when leave succeeds
                    UpdatedJoined = maps:remove(Channel, Joined_Channels),
                    {reply, ok, St#client_st{joined_channels = UpdatedJoined}};
                timeout_error ->
                    {reply, {error, server_not_reached,
                             "Server is non-responsive. Failed to leave channel: " ++ Channel}, St};
                user_not_joined ->
                    {reply, {error, user_not_joined,
                             "User has not joined channel. Failed to leave channel: " ++ Channel}, St};
                {error, Reason} ->
                    {reply, {error, Reason, "Failed to leave channel"}, St}
            end
    end;

%% ---------------------------------------------------------------------------
%% SEND MESSAGE TO CHANNEL
%% ---------------------------------------------------------------------------
% Handle message send request:
% - Verify user has joined the target channel
% - Forward message to the channel process
% - Return ok on success, or an appropriate error if failed
handle(St = #client_st{server = Server, nick = Nick, client_id = Client_Id,
                       joined_channels = Joined_Channels},
       {message_send, Channel, Msg}) ->
    case maps:is_key(Channel, Joined_Channels) of
        true ->
            case whereis(list_to_atom(Channel)) of
                undefined ->
                    {reply, {error, server_not_reached,
                             "Server cannot be reached. Failed to send message to channel: " ++ Channel}, St};
                _ ->
                    ChannelRef = maps:get(Channel, Joined_Channels),
                    case genserver:request(ChannelRef, {message_send, Nick, Msg, Client_Id}) of
                        user_not_joined ->
                            {reply, {error, user_not_joined,
                                     "User has not joined channel. Failed to send message to channel: " ++ Channel}, St};
                        {error, Reason} ->
                            {reply, {error, Reason, "Failed to send message"}, St};
                        ok ->
                            {reply, ok, St}
                    end
            end;
        false ->
            case genserver:request(Server, {doesChannelExist, Channel}) of
                channel_doesnt_exist ->
                    {reply, {error, server_not_reached,
                             "Channel does not exist on server: " ++ Channel}, St};
                {error, _} ->
                    {reply, {error, user_not_joined,
                             "User has not joined channel: " ++ Channel}, St};
                _ ->
                    {reply, {error, user_not_joined,
                             "User has not joined channel: " ++ Channel}, St}
            end
    end;

%% ---------------------------------------------------------------------------
%% CHANGE NICKNAME
%% ---------------------------------------------------------------------------
% Handle nickname change:
% - Check if server is reachable
% - Send request to change old nickname to new nickname
% - Update client state on success, return error on failure
handle(St = #client_st{server = Server, nick = OldNick}, {nick, NewNick}) ->
    case whereis(Server) of
        undefined ->
            {reply, {error, server_not_reached, "Server cannot be reached. Failed to change nick"}, St};
        ServerPid ->
            case catch genserver:request(ServerPid, {change_nick, OldNick, NewNick}, 2000) of
                ok ->
                    {reply, ok, St#client_st{nick = NewNick}};
                nick_taken ->
                    {reply, {error, nick_taken, "Nickname already in use: " ++ NewNick}, St};
                timeout_error ->
                    {reply, {error, server_not_reached, "Server is non-responsive. Failed to change nick"}, St};
                {error, Reason} ->
                    {reply, {error, Reason, "Failed to change nick"}, St}
            end
    end;

% ---------------------------------------------------------------------------
% The cases below do not need to be changed...
% But you should understand how they work!

% Get current nick
handle(St, whoami) ->
    {reply, St#client_st.nick, St} ;

% Incoming message (from channel, to GUI)
handle(St = #client_st{gui = GUI}, {message_receive, Channel, Nick, Msg}) ->
    gen_server:call(GUI, {message_receive, Channel, Nick++"> "++Msg}),
    {reply, ok, St} ;

% Quit client via GUI
handle(St = #client_st{server = Server, client_id = Client_Id, joined_channels = Joined_Channels}, quit) ->
    % Leave all joined channels
    lists:foreach(
        fun(Channel) ->
            catch genserver:request(Server, {leave, Client_Id, Channel})
        end,
        maps:keys(Joined_Channels)
    ),
    {reply, ok, St#client_st{joined_channels = #{}}};

% Catch-all for any unhandled requests
handle(St, _) ->
    {reply, {error, not_implemented, "Client does not handle this command"}, St} .