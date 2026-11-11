//// Fan-out of newly accepted events to every connected client.
////
//// The hub only keeps the set of live connections. Each connection process
//// matches events against its own subscriptions, so filter evaluation is
//// spread across the BEAM schedulers instead of serialized here.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/set.{type Set}
import nostr_relay/event.{type Event}

pub type Message {
  Register(Subject(Event))
  Unregister(Subject(Event))
  Broadcast(Event)
}

pub fn start() -> Result(Subject(Message), actor.StartError) {
  actor.new(set.new())
  |> actor.on_message(handle)
  |> actor.start
  |> fn(r) {
    case r {
      Ok(started) -> Ok(started.data)
      Error(e) -> Error(e)
    }
  }
}

fn handle(
  conns: Set(Subject(Event)),
  msg: Message,
) -> actor.Next(Set(Subject(Event)), Message) {
  case msg {
    Register(conn) -> actor.continue(set.insert(conns, conn))
    Unregister(conn) -> actor.continue(set.delete(conns, conn))
    Broadcast(ev) -> {
      set.each(conns, process.send(_, ev))
      actor.continue(conns)
    }
  }
}
