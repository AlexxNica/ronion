# Ronion anonymous routing protocol framework specification

Specification version: 0.0.8

Author: Nazar Mokrynskyi

License: Ronion anonymous routing protocol framework specification (this document) is hereby placed in the public domain

### Introduction
This document is a textual specification of the Ronion anonymous routing protocol framework.
The goal of this document is to give enough guidance to permit a complete and correct implementation of the protocol.

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED",  "MAY", and "OPTIONAL" in this document are to be interpreted as described in IETF [RFC 2119](http://www.ietf.org/rfc/rfc2119.txt).

#### Glossary
* Initiator: the node that initiates communication
* Responder: the node with which initiator wants to communicate with
* Routing path: a sequence of nodes that form a path through which initiator and responder are connected and can anonymously send encrypted data
* Routing path segment: part of routing path between 2 adjacent nodes, on each node routing path segment is identified using routing path segment identifier and address of the node on the other end of the segment
* Packet: set of bytes to be transferred from one node to another
* Application: software that uses implementation of this protocol

#### Assumptions
The only assumption about encryption algorithm used is that authenticated encryption is used (application MUST specify MAC length in bytes).

2 assumptions about transport layer used are:
* it delivers data in the same order as the data were sent (think TCP instead of UDP)
* transport layer itself uses secure encryption between any 2 nodes between initiator and observer (using non-encrypted link between more than 1 pair of nodes available to observer will allow observer to track the same message appearing in multiple locations)

#### Goals
The goals of this protocol framework are:
* anonymizing the connection between initiator and responder so that nodes in routing path don't know who is initiator and who is responder
* anonymizing the connection between initiator and responder so that responder doesn't know who initiator is and doesn't know its address
* hiding exact number of intermediate nodes used from any node in routing path including responder as well as limited observer
* hiding exact size and contents of the transmitted data sent from initiator to responder and backwards from any of the node in routing path as well as global observer
* allow application to use its own encryption algorithm, transport layer and data structures of the messages

Ronion depends heavily on application's decisions and tries to stay away from enforcing implementation details as much as possible, while still providing easy to follow framework for building secure and anonymous communication.

#### Numbers
All numbers are unsigned integers in big endian format.

#### Address
Address format is defined by application and MUST have constant length.

#### Encryption
`{}` means data are encrypted (as the result of consuming `CREATE_REQUEST` and `CREATE_RESPONSE` and establishing corresponding encryption keys) and current node is capable of encrypting and/or decrypting it.
MAC is assumed to be present after encrypted data, but not shown explicitly.

#### Data structure notation
`[]` is used to specify a distinct piece of raw data (encrypted if placed under `{}`).
The size of the data piece is specified in bytes after colon like this: `[data: 2]`, if no size specified, then data occupies the rest of available space.
Exact value can be specified after data piece size separated by coma: `[data: 2, 1]`.

#### Packet format
```
[version: 1][segment_id: 2][packet_data]
```

`[version]` encapsulates address format, crypto algorithms used, set of commands and other important details used on that connection, supplied by application.
Version is kept the same on each hop of the same routing path and never changes in the middle of the routing path.
`[segment_id]` is unique to each segment of the network, the response MUST always preserve `[segment_id]` of the request so that it is clear where to send it further.

#### Packet size
Total packet size is fixed and configured by application, padding with random bytes is used when needed as described in corresponding sections.

It is responsibility of the application to carefully count how many bytes can be sent in each particular command type with selected encryption algorithm and make sure data will fit into one packet (or split data into multiple packets if needed).

#### [random_bytes_padding]
Is used at the end of the packet to fill it til packet size (so that all packets have the same size).

#### Commands
Commands explain what node MUST do with the packet it has received, supported commands are listed below.

Each command is represented by number from the range `1..255`.
The list of supported commands is given below, unused numbers are reserved for future versions of the specification:

| Command name    | Numeric value |
|-----------------|---------------|
| CREATE_REQUEST  | 1             |
| CREATE_RESPONSE | 2             |
| EXTEND_REQUEST  | 3             |
| EXTEND_RESPONSE | 4             |
| DESTROY         | 5             |
| DATA            | 6             |

### Routing path construction
Routing path construction is started by initiator with sending `CREATE_REQUEST` command to the first node in routing path in order to create the first routing path segment.
Then initiator sends `EXTEND_REQUEST` command to the first node in order to extend the routing path by one more segment to the second node.
Initiator keeps sending `EXTEND_REQUEST` commands to the last node in current routing path until last node in routing path is responder, at which point routing path is ready to send data back and forth.

### Plain text commands
These commands are used prior to establishing routing path segments with specified `[segment_id]`, as soon as routing path segment is established only encrypted commands MUST be accepted.

#### CREATE_REQUEST
Is sent when creating segment of routing path is needed, can be send multiple times to the same node if multiple roundtrips are needed.

Request data:
```
[command: 1, 1][segment_creation_request_data_length: 2][segment_creation_request_data: segment_creation_request_data_length][random_bytes_padding]
```

Request data handling:
* `[segment_creation_request_data]` is consumed by the node in order to generate keys for routing path segment creation
* `[segment_id]` is linked by protocol implementation with address of the node where `CREATE_REQUEST` came from, together `[segment_id]` and node address uniquely identify routing path segment
* responds to the previous node with `CREATE_RESPONSE` command

#### CREATE_RESPONSE
Is sent as an answer to `CREATE_REQUEST`, is sent exactly once in response to each `CREATE_REQUEST`.

Response data:
```
[command: 1, 2][segment_creation_response_data_length: 2][segment_creation_response_data: segment_creation_response_data_length][random_bytes_padding]
```

Response data handling:
* if current node has initiated `CREATE_REQUEST` then `[segment_creation_response_data]` is consumed by the node in order to perform routing path segment creation
* if current node has not initiated `CREATE_REQUEST`, but instead it `EXTEND_REQUEST` command was sent by another node, `EXTEND_RESPONSE` is generated in response

### Encrypted commands
These commands are used after establishing routing path segment with specified `[segment_id]` and corresponding node address.

Each encrypted command request data follows following pattern:
```
{[command: 1][command_data_length: 2]}[command_data]
```

Where `[command_data_length]` bytes of `[command_data]` (not including MAC) also belong to the command, are encrypted separately and their meaning depends on the command.

#### EXTEND_REQUEST command
Is used in order to extend routing path one segment further, effectively generates `CREATE_REQUEST` to the next node.

If `[segment_id]` was previously extended to another node, that link between `[segment_id]` of the previous node and `[segment_id]` of the next node MUST be destroyed and new routing path extension MUST be performed.

Request data:
```
{[command: 1, 3][address_and_segment_creation_request_data_length: 2]}{[next_node_address][segment_creation_request_data]}[random_bytes_padding]
```

Request data handling:
* decrypt command and command data length
* if command is `EXTEND_REQUEST`, then decrypt `[next_node_address]` and `[segment_creation_request_data]` then send `CREATE_REQUEST` command to the `[next_node_address]` using newly generated `[segment_id]` for that segment
* `[segment_id]` of the previous node and `[segment_id]` of the next node MUST be linked together by protocol implementation for future data forwarding

`CREATE_REQUEST` request data being sent:
```
[command: 1, 4][segment_creation_request_data_length: 2][segment_creation_request_data: segment_creation_request_data_length][random_bytes_padding]
```

#### EXTEND_RESPONSE command
Is used in order to extend routing path one segment further, effectively wraps `CREATE_RESPONSE` from next node and send it to the previous node.

Response data:
```
{[command: 1, 4][segment_creation_response_data_length][segment_creation_response_data]}[random_bytes_padding]
```

Where `[segment_creation_response_data_length][segment_creation_response_data]` part is taken from the beginning of the `CREATE_RESPONSE` data directly.

Response data handling:
* if `[segment_creation_response_data_length]` has value `0`, it means that routing path creation has failed (can happen if node can't extend the routing path, for instance, when node with specified address doesn't exist)

#### DESTROY command
Is used in order to destroy certain segment of the routing path. This command MUST always be sent to the last node in the routing path.

Request data:
```
{[command: 1, 5][length: 2, 0]}[random_bytes_padding]
```

No response is needed for this command, can be sent to nodes if unsure whether node is still alive and will actually receive the message.

After dropping the segment of the routing path, the last node left in the routing path can be used to again extend routing path to another node.

#### DATA command
Is used to actually transfer useful data between applications on different nodes.

`DATA` command doesn't differentiate request from response, it just send data, application layer SHOULD also take care of delivery confirmations if necessary, since this is not done by protocol either.

`DATA` command can be sent by:
* initiator towards any node in the routing path, including responder
* any node in the routing path, including responder, towards initiator

Request data:
```
{[command: 1, 6][data_length: 2]}{[data]}[random_bytes_padding]
```

#### Data forwarding
Only works after `EXTEND_REQUEST` and `EXTEND_RESPONSE` happened before, so that node knows where to send data next.

Forwarding is happening when node can't decrypt the command, which in turn means that the command was not intended for this node.
Also all of the data moving in direction from responder to initiator are forwarded without command decryption attempt.

Initiator upon receiving the data tries to decrypt data with keys that correspond to each node in routing path until it decrypts data successfully.
The order in which keys are selected is up to the application or implementation, generally starting from the keys of the last node in the routing path and moving to the first node is a good idea.

#### Dropping packets
If packets were forwarded through the whole routing path and the last node (either initiator or responder) still can't decrypt the packet, the packet is silently dropped.
If packet is decrypted successfully, but command is unknown, the packet is silently dropped.
Undecryptable or packets with non-existing command (just to stop data from moving to the next node) can be used to generate fake activity.

### Security and anonymity considerations for an application developer
Here is the list of things an application developer SHOULD consider in order to have secure and anonymous communication:
* application MUST always use authenticated encryption
* padding MUST always use random bytes and MUST NOT re-use the same random bytes again
* initiator MUST use separate temporary keys for each node and each `[segment_id]` it communicates with and MUST never re-use the same keys for different nodes or different `[segment_id]` again
* application on any node MIGHT want to send fake packets, apply custom delays between sending packets and forward packets from independent `[segment_id]` in different order than they have come to the node in order to confuse an observer
