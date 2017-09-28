/**
 * @package   Ronion
 * @author    Nazar Mokrynskyi <nazar@mokrynskyi.com>
 * @copyright Copyright (c) 2017, Nazar Mokrynskyi
 * @license   MIT License, see license.txt
 */
async-eventer	= require('async-eventer')
randombytes		= require('randombytes')

module.exports = Ronion

const COMMAND_CREATE_REQUEST	= 1
const COMMAND_CREATE_RESPONSE	= 2
const COMMAND_EXTEND_REQUEST	= 3
const COMMAND_EXTEND_RESPONSE	= 4
const COMMAND_DESTROY			= 5
const COMMAND_DATA				= 6

/**
 * @param {Uint8Array} array
 *
 * @return {number}
 */
function uint_array_to_number (array)
	array[0] * 256 + array[1]

/**
 * @param {number} number
 *
 * @return {Uint8Array}
 */
function number_to_uint_array (number)
	lsb	= number % 256
	msb	= (number - lsb) / 256
	Uint8Array.of(msb, lsb)

/**
 * @param {Uint8Array} packet
 *
 * @return {array} [version: number, segment_id: Uint8Array]
 */
function parse_packet_header (packet)
	# First byte is version, next 2 bytes are segment_id
	[packet[0], packet.subarray(1, 2)]

/**
 * @param {Uint8Array} packet_data
 *
 * @return {number[]} [command, command_data_length]
 */
function parse_packet_data_header (packet_data)
	# First byte is command, next 2 bytes are command data length as unsigned integer in big endian format
	[packet_data[0], uint_array_to_number(packet_data.subarray(1, 3))]

/**
 * @param {Uint8Array} packet_data
 *
 * @return {array} [command: number, command_data: Uint8Array]
 */
function parse_packet_data_plaintext (packet_data)
	[command, command_data_length]	= parse_packet_data_header(packet_data)
	[command, packet_data.slice(3, 3 + command_data_length)]

/**
 * @param {number}		packet_size
 * @param {number}		version
 * @param {Uint8Array}	segment_id
 * @param {Uint8Array}	packet_data_header
 * @param {Uint8Array}	command_data
 *
 * @return {Uint8Array}
 */
function generate_packet (packet_size, version, segment_id, packet_data_header, command_data)
	packet						= new Uint8Array(packet_size)
		..set([version])
		..set(segment_id, 1)
		..set(packet_data_header, 3)
		..set(command_data, 3 + packet_data_header.length)
	bytes_written				= 3 + packet_data_header.length + command_data.length
	random_bytes_padding_length	= packet_size - bytes_written
	if random_bytes_padding_length
		packet.set(randombytes(random_bytes_padding_length), bytes_written)
	packet

/**
 * @param {number}	command
 * @param {number}	command_data_length
 *
 * @return {Uint8Array}
 */
function generate_packet_data_header (command, command_data_length)
	# First byte is command, next 2 bytes are command data length as unsigned integer in big endian format
	new Uint8Array(3)
		..set(command)
		..set(number_to_uint_array(command_data_length), 1)

/**
 * @param {Uint8Array}	address
 * @param {Uint8Array}	segment_id
 *
 * @return {string}
 */
function compute_source_id (address, segment_id)
	address.join('') + segment_id.join('')

/**
 * @constructor
 *
 * @param {number}	version			0..255
 * @param {number}	packet_size
 * @param {number}	address_length
 * @param {number}	mac_length
 */
!function Ronion (version, packet_size, address_length, mac_length)
	if !(@ instanceof Ronion)
		return new Ronion(version, packet_size, address_length, mac_length)
	async-eventer.call(@)

	@_version						= version
	@_packet_size					= packet_size
	@_address_length				= address_length
	@_mac_length					= mac_length
	# Map of established segments (first node in routing path) to list of nodes in routing path
	@_established_segments			= new Map
	# Map of segments that were created for extension purposes to the node where extension request come from, but didn't receive response from extension yet
	@_pending_extension_segments	= new Map
	# Map of segments on which extension has started to the address where routing path is going to be extended, but didn't receive extension confirmation yet
	@_pending_extensions			= new Map
	# Map of segments where data can come from to segment where data should be forwarded to if can't be decrypted, each mapping results in 2 elements, one for each direction
	@_segments_forwarding_mapping	= new Map

Ronion:: =
	/**
	 * Must be called when new packet appear
	 *
	 * @param {Uint8Array}	address	Address (in application-specific format) where packet came from
	 * @param {Uint8Array}	packet	Packet
	 */
	process_packet : (address, packet) !->
		# Do nothing if packet or its size is incorrect
		if packet.length != @_packet_size
			return
		[version, segment_id]	= parse_packet_header(packet)
		# Do nothing the version is unsupported
		if version != @_version
			return
		source_id	= compute_source_id(address, segment_id)
		packet_data	= packet.subarray(3)
		# If segment is not established then we don't use encryption yet
		if @_established_segments.has(source_id)
			@_process_packet_data_encrypted(source_id, packet_data)
		else
			@_process_packet_data_plaintext(address, segment_id, packet_data)
	/**
	 * Must be called when new segment is established with node that has specified address
	 *
	 * @param {Uint8Array}	address
	 * @param {Uint8Array}	segment_id
	 */
	confirm_established_segment : (address, segment_id) !->
		source_id	= compute_source_id(address, segment_id)
		@_established_segments.set(source_id, [address])
	/**
	 * Must be called when new segment is established with node that has specified address
	 *
	 * @param {Uint8Array}	address		Node at which to start routing path
	 * @param {Uint8Array}	segment_id	Same segment ID as in CREATE_REQUEST
	 */
	confirm_extended_path : (address, segment_id) !->
		source_id			= compute_source_id(address, segment_id)
		next_node_address	= @_pending_extensions.get(source_id)
		@_established_segments.get(source_id).push(next_node_address)
		@_pending_extensions.delete(source_id)
	/**
	 * Must be called in order to start new routing path, sends CREATE_REQUEST
	 *
	 * @param {Uint8Array}	address			Node at which to start routing path
	 * @param {Uint8Array}	command_data
	 *
	 * @return {Uint8Array} segment_id Generated segment ID that can be later used for routing path extension
	 *
	 * @throws {RangeError}
	 */
	create_request : (address, command_data) ->
		segment_id			= @_generate_segment_id(address)
		packet_data_header	= generate_packet_data_header(COMMAND_CREATE_REQUEST, command_data.length)
		packet				= generate_packet(@_packet_size, @_version, segment_id, packet_data_header, command_data)
		@fire('send', {address, packet})
		segment_id
	/**
	 * @param {Uint8Array} address
	 *
	 * @return {Uint8Array}
	 */
	_generate_segment_id : (address) ->
		for i from 0 til 2^16
			segment_id	= number_to_uint_array(i)
			source_id	= compute_source_id(address, segment_id)
			if !@_established_segments.has(source_id) && !@_pending_extension_segments.has(source_id)
				return segment_id
		throw new RangeError('Out of possible segment IDs')
	/**
	 * Must be called in order to respond to CREATE_RESPONSE
	 *
	 * @param {Uint8Array}	address			Node from which CREATE_REQUEST come from
	 * @param {Uint8Array}	segment_id		Same segment ID as in CREATE_REQUEST
	 * @param {Uint8Array}	command_data
	 */
	create_response : (address, segment_id, command_data) !->
		packet_data_header	= generate_packet_data_header(COMMAND_CREATE_RESPONSE, command_data.length)
		packet				= generate_packet(@_packet_size, @_version, segment_id, packet_data_header, command_data)
		@fire('send', {address, packet})
	/**
	 * Must be called in order to extend routing path by one more segment, sends EXTEND_REQUEST
	 *
	 * @param {Uint8Array}	address				Node at which routing path has started
	 * @param {Uint8Array}	segment_id			Same segment ID as returned by CREATE_REQUEST
	 * @param {Uint8Array}	next_node_address	Node to which routing path will be extended from current last node
	 * @param {Uint8Array}	command_data
	 *
	 * @throws {ReferenceError}
	 */
	extend_request : (address, segment_id, next_node_address, command_data) !->
		source_id	= compute_source_id(address, segment_id)
		if !@_established_segments.has(source_id)
			throw new ReferenceError('There is no such segment established')
		target_address					= @_established_segments.get(source_id).slice(-1)[0]
		packet_data_header				= generate_packet_data_header(COMMAND_EXTEND_REQUEST, command_data.length)
		(packet_data_header_encrypted)	<~! @_encrypt(address, segment_id, target_address, packet_data_header)
		command_data					= new Uint8Array(next_node_address.length + command_data.length)
			..set(next_node_address)
			..set(command_data, next_node_address.length)
		(command_data_encrypted)		<~! @_encrypt(address, segment_id, target_address, command_data)
		packet							= generate_packet(@_packet_size, @_version, segment_id, packet_data_header_encrypted, command_data_encrypted)
		@fire('send', {address, packet})
		@_pending_extensions.set(source_id, next_node_address)
	/**
	 * @param {Uint8Array}	address
	 * @param {Uint8Array}	segment_id
	 * @param {Uint8Array}	command_data
	 */
	_extend_response : (address, segment_id, command_data) !->
		packet_data_header				= generate_packet_data_header(COMMAND_EXTEND_RESPONSE, command_data.length)
		(packet_data_header_encrypted)	<~! @_encrypt(address, segment_id, address, packet_data_header)
		(command_data_encrypted)		<~! @_encrypt(address, segment_id, address, command_data)
		packet							= generate_packet(@_packet_size, @_version, segment_id, packet_data_header_encrypted, command_data_encrypted)
		@fire('send', {address, packet})
	/**
	 * @param {Uint8Array}	address
	 * @param {Uint8Array}	segment_id
	 * @param {Uint8Array}	packet_data
	 */
	_process_packet_data_plaintext : (address, segment_id, packet_data) !->
		[command, command_data]	= parse_packet_data_plaintext(packet_data)
		switch command
			case COMMAND_CREATE_REQUEST
				@fire('create_request', {address, segment_id, command_data})
			case COMMAND_CREATE_RESPONSE
				source_id	= compute_source_id(address, segment_id)
				if @_pending_extension_segments.has(source_id)
					original_source	= @_pending_extension_segments.get(source_id)
					@_pending_extension_segments.delete(source_id)
					@_extend_response(original_source.address, original_source.segment_id, command_data)
					@_add_segments_forwarding_mapping(address, segment_id, original_source.address, original_source.segment_id)
				else
					# TODO: Should this event be fired in any case?
					# After at least one create_response event received routing path segment should be considered half-established and destroy() should be called
					# in order to drop half-established routing path segment
					@fire('create_response', {address, segment_id, command_data})
		@fire('send', {address, packet})
	/**
	 * @param {Uint8Array}	address1
	 * @param {Uint8Array}	segment_id1
	 * @param {Uint8Array}	address2
	 * @param {Uint8Array}	segment_id2
	 */
	_add_segments_forwarding_mapping : (address1, segment_id1, address2, segment_id2) !->
		source_id1	= compute_source_id(address1, segment_id1)
		source_id2	= compute_source_id(address2, segment_id2)
		@_segments_forwarding_mapping.set(source_id1, source_id2)
		@_segments_forwarding_mapping.set(source_id2, source_id1)
	/**
	 * @param {Uint8Array}	address
	 * @param {Uint8Array}	segment_id
	 */
	_del_segments_forwarding_mapping : (address, segment_id) !->
		source_id1	= compute_source_id(address, segment_id)
		if @_segments_forwarding_mapping.has(source_id1)
			source_id2	= @_segments_forwarding_mapping.get(source_id1)
			@_segments_forwarding_mapping.delete(source_id1)
			@_segments_forwarding_mapping.delete(source_id2)
	/**
	 * @param {Uint8Array}	address
	 * @param {Uint8Array}	segment_id
	 * @param {Uint8Array}	packet_data
	 */
	_process_packet_data_encrypted : (address, segment_id, packet_data) !->
		# Packet data header size + MAC
		packet_data_header_encrypted	= packet_data.slice(0, 3 + @_mac_length)
		(packet_data_header)			<~! @_decrypt(address, segment_id, address, packet_data_header_encrypted)
		[command, command_data_length]	= parse_packet_data_header(packet_data_header)
		command_data_encrypted			= packet_data.slice(packet_data_header_encrypted.length, packet_data_header_encrypted.length + command_data_length)
		(command_data)					<~! @_decrypt(address, segment_id, address, command_data_encrypted)
		switch command
			case COMMAND_EXTEND_REQUEST
				try
					next_node_address				= command_data.subarray(0, @_address_length)
					segment_creation_request_data	= command_data.subarray(@_address_length)
					next_node_segment_id			= @create_request(next_node_address, segment_creation_request_data)
					next_node_source_id				= compute_source_id(next_node_address, next_node_segment_id)
					@_pending_extension_segments.set(next_node_source_id, {address, segment_id})
				catch
					# Send empty CREATE_RESPONSE indicating that it is not possible to extend routing path
					@create_response(address, segment_id, new Uint8Array)
					return
			case COMMAND_EXTEND_RESPONSE
				source_id	= compute_source_id(address, segment_id)
				if @_pending_extensions.has(source_id)
					@fire('extend_response', {address, segment_id, command_data})
			case COMMAND_DESTROY
				# TODO
				void
			case COMMAND_DATA
				@fire('data', {address, segment_id, command_data})
		# TODO: forward data that can't be decrypted and there is mapping to the next node
	/**
	 * @param {Uint8Array}	address			Node at which routing path has started
	 * @param {Uint8Array}	segment_id		Same segment ID as returned by CREATE_REQUEST
	 * @param {Uint8Array}	target_address	Address for which to encrypt (can be the same as address argument or any other node in routing path)
	 * @param {Uint8Array}	plaintext
	 *
	 * @return {Promise} Will resolve with Uint8Array ciphertext if encrypted successfully
	 */
	_encrypt : (address, segment_id, target_address, plaintext) ->
		data	= {address, segment_id, target_address, plaintext, ciphertext : null}
		promise	= @fire('encrypt', data).then ~>
			ciphertext	= data.ciphertext
			if !(ciphertext instanceof Uint8Array) || ciphertext.length != (plaintext.length + @_mac_length)
				throw new Error('Encryption failed')
			ciphertext
		promise.catch(->) # Just to avoid unhandled promise rejection
		promise
	/**
	 * @param {Uint8Array}	address			Node at which routing path has started
	 * @param {Uint8Array}	segment_id		Same segment ID as returned by CREATE_REQUEST
	 * @param {Uint8Array}	target_address	Address from which to decrypt (can be the same as address argument or any other node in routing path)
	 * @param {Uint8Array}	ciphertext
	 *
	 * @return {Promise} Will resolve with Uint8Array plaintext if decrypted successfully
	 */
	_decrypt : (address, segment_id, target_address, ciphertext) ->
		# TODO: encrypted contents for initiator can be sent from any node in routing path, so it is necessary to try to decrypt message as it comes from any node
		data	= {address, segment_id, target_address, ciphertext, plaintext : null}
		promise	= @fire('decrypt', data).then ~>
			plaintext	= data.plaintext
			if !(plaintext instanceof Uint8Array) || plaintext.length != (ciphertext.length - @_mac_length)
				throw new Error('Decryption failed')
			plaintext
		promise.catch(->) # Just to avoid unhandled promise rejection
		promise

Ronion:: = Object.assign(Object.create(async-eventer::), Ronion::)

Object.defineProperty(Ronion::, 'constructor', {enumerable: false, value: Ronion})
