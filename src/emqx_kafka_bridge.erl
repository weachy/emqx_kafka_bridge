%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_kafka_bridge).

-include_lib("emqx/include/emqx.hrl").

-export([load/1, unload/0]).

-define(APP, emqx_kafka_bridge).

%% Hooks functions
-export([on_client_connected/4, on_client_disconnected/3]).
-export([on_client_subscribe/3, on_client_unsubscribe/3]).
-export([on_session_created/3, on_session_resumed/3, on_session_terminated/3]).
-export([on_session_subscribed/4, on_session_unsubscribed/4]).
-export([on_message_publish/2, on_message_delivered/3, on_message_acked/3, on_message_dropped/3]).

%% Called when the plugin application start
load(Env) ->
    brod_init([Env]),
    emqx:hook('client.connected', fun ?MODULE:on_client_connected/4, [Env]),
    emqx:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
    emqx:hook('client.subscribe', fun ?MODULE:on_client_subscribe/3, [Env]),
    emqx:hook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3, [Env]),
    emqx:hook('session.created', fun ?MODULE:on_session_created/3, [Env]),
    emqx:hook('session.resumed', fun ?MODULE:on_session_resumed/3, [Env]),
    emqx:hook('session.subscribed', fun ?MODULE:on_session_subscribed/4, [Env]),
    emqx:hook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4, [Env]),
    emqx:hook('session.terminated', fun ?MODULE:on_session_terminated/3, [Env]),
    emqx:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
    emqx:hook('message.delivered', fun ?MODULE:on_message_delivered/3, [Env]),
    emqx:hook('message.acked', fun ?MODULE:on_message_acked/3, [Env]),
    emqx:hook('message.dropped', fun ?MODULE:on_message_dropped/3, [Env]).

%% 客户端上线
on_client_connected(#{client_id := ClientId}, ConnAck, ConnAttrs, _Env) ->
    io:format("Client(~s) connected, connack: ~w, conn_attrs:~p~n", [ClientId, ConnAck, ConnAttrs]).

%% 客户端连接断开
on_client_disconnected(#{client_id := ClientId, username := Username}, ReasonCode, _Env) ->
    io:format("Client(~s) disconnected, reason_code: ~w~n", [ClientId, ReasonCode]),
    Now = erlang:timestamp(),
    Payload = [{client_id, ClientId}, {node, node()}, {username, Username}, {reason, ReasonCode}, {ts, emqx_time:now_secs(Now)}],
    Disconnected = proplists:get_value(disconnected, _Env),
    produce_kafka_payload(Disconnected, Username, Payload, _Env),
    ok.

%% 客户端订阅主题
on_client_subscribe(#{client_id := ClientId}, RawTopicFilters, _Env) ->
    io:format("Client(~s) will subscribe: ~p~n", [ClientId, RawTopicFilters]),
    {ok, RawTopicFilters}.

%% 客户端取消订阅主题
on_client_unsubscribe(#{client_id := ClientId}, RawTopicFilters, _Env) ->
    io:format("Client(~s) unsubscribe ~p~n", [ClientId, RawTopicFilters]),
    {ok, RawTopicFilters}.

%% 会话创建
on_session_created(#{client_id := ClientId}, SessAttrs, _Env) ->
    io:format("Session(~s) created: ~p~n", [ClientId, SessAttrs]),
    Now = erlang:timestamp(),
    Username = proplists:get_value(username, SessAttrs),
    Payload = [{client_id, ClientId}, {username, Username}, {node, node()},  {ts, emqx_time:now_secs(Now)}],
    Connected = proplists:get_value(connected, _Env),
    produce_kafka_payload(Connected, Username, Payload, _Env).

%% 会话恢复
on_session_resumed(#{client_id := ClientId}, SessAttrs, _Env) ->
    io:format("Session(~s) resumed: ~p~n", [ClientId, SessAttrs]).

%% 会话订阅主题后
on_session_subscribed(#{client_id := ClientId, username := Username}, Topic, SubOpts, _Env) ->
    io:format("Session(~s) subscribe ~s with subopts: ~p~n", [ClientId, Topic, SubOpts]),
    Now = erlang:timestamp(),
    Payload = [{client_id, ClientId}, {node, node()}, {username, Username}, {topic, Topic}, {ts, emqx_time:now_secs(Now)}],
    Subscribed = proplists:get_value(subscribed, _Env),
    produce_kafka_payload(Subscribed, Username, Payload, _Env).

%% 会话取消订阅主题后
on_session_unsubscribed(#{client_id := ClientId}, Topic, Opts, _Env) ->
    io:format("Session(~s) unsubscribe ~s with opts: ~p~n", [ClientId, Topic, Opts]).

%% 会话终止
on_session_terminated(#{client_id := ClientId}, ReasonCode, _Env) ->
    io:format("Session(~s) terminated: ~p.", [ClientId, ReasonCode]).

%% Transform message and return
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message = #message{id = MsgId,
                        qos = Qos,
                        from = From,
                        flags = Flags,
                        topic  = Topic,
                        payload = Payload,
                        timestamp  = Time
						}, _Env) -> 
    io:format("publish ~s~n", [emqx_message:format(Message)]),
    MP =  proplists:get_value(regex, _Env),
    case re:run(Topic, MP, [{capture, all_but_first, list}]) of
       nomatch -> {ok, Message};
       match -> io:format("publish to kafka topic ~s", [Topic]),
          Key = iolist_to_binary([Topic]),
          Partition = proplists:get_value(partition, _Env),
          Now = erlang:timestamp(),
          Msg = [{client_id, From}, {node, node()}, {qos, Qos}, {payload, Payload}, {ts, emqx_time:now_secs(Now)}],
          {ok, MessageBody} = emqx_json:safe_encode(Msg),
          MsgPayload = iolist_to_binary(MessageBody),
          ok = brod:produce_sync(brod_client_1, "mqtt_to_kafka", getPartiton(Key,Partition), Key, MsgPayload),
       {ok, Message}
    end.

%% MQTT 消息进行投递
on_message_delivered(#{client_id := ClientId}, Message, _Env) ->
    io:format("Delivered message to client(~s): ~s~n", [ClientId, emqx_message:format(Message)]),
    {ok, Message}.

%% MQTT 消息回执
on_message_acked(#{client_id := ClientId}, Message, _Env) ->
    io:format("Session(~s) acked message: ~s~n", [ClientId, emqx_message:format(Message)]),
    {ok, Message}.

%% MQTT 消息丢弃
on_message_dropped(_By, #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    ok;
on_message_dropped(#{node := Node}, Message, _Env) ->
    io:format("Message dropped by node ~s: ~s~n", [Node, emqx_message:format(Message)]);
on_message_dropped(#{client_id := ClientId}, Message, _Env) ->
    io:format("Message dropped by client ~s: ~s~n", [ClientId, emqx_message:format(Message)]).

brod_init(_Env) ->
    {ok, _} = application:ensure_all_started(brod),
    {ok, BootstrapBroker} = application:get_env(?APP, broker),
    {ok, ClientConfig} = application:get_env(?APP, client),
    ok = brod:start_client(BootstrapBroker, brod_client_1, ClientConfig),
    io:format("Init EMQX-Kafka-Bridge with ~p~n", [BootstrapBroker]).

getPartiton(Key, Partitions) ->
     <<Fix:120, Match:8>> = crypto:hash(md5, Key),
     abs(Match) rem Partitions.

%% Called when the plugin application stop
unload() ->
    emqx:unhook('client.connected', fun ?MODULE:on_client_connected/4),
    emqx:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    emqx:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/3),
    emqx:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/3),
    emqx:unhook('session.created', fun ?MODULE:on_session_created/3),
    emqx:unhook('session.resumed', fun ?MODULE:on_session_resumed/3),
    emqx:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
    emqx:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    emqx:unhook('session.terminated', fun ?MODULE:on_session_terminated/3),
    emqx:unhook('message.publish', fun ?MODULE:on_message_publish/2),
    emqx:unhook('message.delivered', fun ?MODULE:on_message_delivered/3),
    emqx:unhook('message.acked', fun ?MODULE:on_message_acked/3),
    emqx:unhook('message.dropped', fun ?MODULE:on_message_dropped/3).

produce_kafka_payload(Key, Username, Message, _Env) ->
    {ok, MessageBody} = emqx_json:safe_encode(Message),
    % MessageBody64 = base64:encode_to_string(MessageBody),
    Payload = iolist_to_binary(MessageBody),
    Partition = proplists:get_value(partition, _Env),
    Topic = iolist_to_binary(Key),
    brod:produce_sync(brod_client_1, Topic, getPartiton(Username,Partition), Username, Payload).
