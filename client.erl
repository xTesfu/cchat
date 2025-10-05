-module(client).
-export([handle/2, initial_state/3]).

%%====================================================================
%% Client State Definition
%%====================================================================

%---------------------------------------------------------------------
% Record: client_st
%
% Fields:
%   gui              - Atom of the GUI process.
%   nick             - Nickname/username of the client.
%   server           - Atom name of the chat server.
%   client_id        - Unique ID for the client.
%   joined_channels  - Map of joined channels and their PIDs.
%---------------------------------------------------------------------
-record(client_st, {
    gui,
    nick,
    server,
    client_id,
    joined_channels
}).

%%====================================================================
%% Utility Functions
%%====================================================================

%---------------------------------------------------------------------
% generate_client_id/0
%
% Generate a unique integer ID for each client.
% - Uses a monotonic, positive integer for uniqueness.
%---------------------------------------------------------------------
generate_client_id() ->
    erlang:unique_integer([monotonic, positive]).

%%====================================================================
%% Initialization
%%====================================================================

%---------------------------------------------------------------------
% initial_state/3
%
% Initialize a new client state record.
% - Nick: Initial nickname for the client.
% - GUIAtom: Atom name of the GUI process.
% - ServerAtom: Atom name of the chat server.
% Returns: #client_st{} record with default joined_channels = #{}.
%---------------------------------------------------------------------
initial_state(Nick, GUIAtom, ServerAtom) ->
    #client_st{
        gui = GUIAtom,
        nick = Nick,
        server = ServerAtom,
        client_id = generate_client_id(),
        joined_channels = #{}
    }.

%%====================================================================
%% Client Request Handling (Main Loop)
%%====================================================================

%---------------------------------------------------------------------
% handle/2 - {join, Channel}
%
% Handle channel join request.
% - Checks if the server process is available.
% - Requests to join the specified channel.
% - On success: updates joined_channels with the channel reference.
% - On failure: returns an error for timeout, already joined, or server issues.
%---------------------------------------------------------------------
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

%---------------------------------------------------------------------
% handle/2 - {leave, Channel}
%
% Handle leave request.
% - Checks if the server is reachable.
% - Sends a leave request to the server.
% - On success: removes the channel from joined_channels.
%---------------------------------------------------------------------
handle(St = #client_st{server = Server, client_id = Client_Id, joined_channels = Joined_Channels},
       {leave, Channel}) ->
    case whereis(Server) of
        undefined ->
            {reply, ok, St};  % Nothing to do if server is unavailable
        _ ->
            case catch genserver:request(Server, {leave, Client_Id, Channel}) of
                ok ->
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

%---------------------------------------------------------------------
% handle/2 - {message_send, Channel, Msg}
%
% Handle message send request.
% - Verifies that the client has joined the target channel.
% - Sends the message via the corresponding channel process.
% - Returns ok on success, or an appropriate error otherwise.
%---------------------------------------------------------------------
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

%---------------------------------------------------------------------
% handle/2 - {nick, NewNick}
%
% Handle nickname change request.
% - Checks if the server is reachable.
% - Requests the server to update nickname mapping.
% - Updates local client state on success.
%---------------------------------------------------------------------
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

%---------------------------------------------------------------------
% handle/2 - whoami
%
% Return the current nickname of the client.
%---------------------------------------------------------------------
handle(St, whoami) ->
    {reply, St#client_st.nick, St};

%---------------------------------------------------------------------
% handle/2 - {message_receive, Channel, Nick, Msg}
%
% Handle incoming messages from a channel.
% - Forwards the message to the GUI process for display.
%---------------------------------------------------------------------
handle(St = #client_st{gui = GUI}, {message_receive, Channel, Nick, Msg}) ->
    gen_server:call(GUI, {message_receive, Channel, Nick ++ "> " ++ Msg}),
    {reply, ok, St};

%---------------------------------------------------------------------
% handle/2 - quit
%
% Handle client quit request from the GUI.
% - Sends leave requests for all joined channels.
% - Clears joined_channels in the client state.
%---------------------------------------------------------------------
handle(St = #client_st{server = Server, client_id = Client_Id, joined_channels = Joined_Channels}, quit) ->
    lists:foreach(
        fun(Channel) ->
            catch genserver:request(Server, {leave, Client_Id, Channel})
        end,
        maps:keys(Joined_Channels)
    ),
    {reply, ok, St#client_st{joined_channels = #{}}};

%---------------------------------------------------------------------
% handle/2 - Unknown
%
% Catch-all for unhandled requests.
% - Returns an error tuple indicating the request is not implemented.
%---------------------------------------------------------------------
handle(St, _) ->
    {reply, {error, not_implemented, "Client does not handle this command"}, St}.