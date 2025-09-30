// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import { OApp, MessagingFee, Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { OAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ABAMock contract for demonstrating LayerZero ABA (ping-pong) messaging pattern
 * @notice THIS IS AN EXAMPLE CONTRACT. DO NOT USE THIS CODE IN PRODUCTION.
 * @dev This contract showcases bidirectional messaging: A -> B -> A using LayerZero's OApp Standard.
 *      When a SEND_ABA message is received, it automatically sends a response back to the origin chain.
 */
contract ABAMock is OApp, OAppOptionsType3 {
    
    /// @notice Last received message data from any chain
    string public data = "Nothing received yet";

    /// @notice Message types that identify different OApp operations
    /// @dev These values are used in combineOptions() for enforced option configuration
    uint16 public constant SEND = 1;      // One-way message (no response expected)
    uint16 public constant SEND_ABA = 2;  // Round-trip message (automatic response)
    
    /// @notice Emitted when a return message is successfully sent (B -> A)
    event ReturnMessageSent(string message, uint32 dstEid);
    
    /// @notice Emitted when a message is received from another chain
    event MessageReceived(string message, uint32 senderEid, bytes32 sender);

    /// @notice Emitted when a message is sent to another chain (A -> B)
    event MessageSent(string message, uint32 dstEid);

    /// @dev Revert with this error when an invalid message type is used
    error InvalidMsgType();

    /**
     * @dev Constructs a new ABAMock contract instance
     * @param _endpoint The LayerZero endpoint for this contract to interact with
     * @param _owner The owner address that will be set as the owner of the contract
     */
    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(msg.sender) {}

    /**
     * @notice Encodes a message with its type and return options for cross-chain transmission
     * @dev The return options are embedded in the message so the receiving chain knows
     *      how much gas to allocate for the B->A return message
     * @param _message The message content to encode
     * @param _msgType The type of message (SEND or SEND_ABA)
     * @param _extraReturnOptions Gas options for the potential return message (B->A)
     * @return Encoded message as bytes
     */
    function encodeMessage(string memory _message, uint16 _msgType, bytes memory _extraReturnOptions) public pure returns (bytes memory) {
        // Get the length of _extraReturnOptions for decoding later
        uint256 extraOptionsLength = _extraReturnOptions.length;

        // Encode the entire message with length markers for proper decoding
        // Format: (message, msgType, optionsLength, options, optionsLength)
        return abi.encode(_message, _msgType, extraOptionsLength, _extraReturnOptions, extraOptionsLength);
    }

    /**
     * @notice Returns the estimated messaging fee for a given message
     * @dev This quotes the cost for the A->B leg. For ABA messages, you need to separately
     *      calculate and include the B->A cost in your gas planning
     * @param _dstEid Destination endpoint ID where the message will be sent
     * @param _msgType The type of message being sent (SEND or SEND_ABA)
     * @param _message The message content
     * @param _extraSendOptions Gas options for the send call (A -> B)
     * @param _extraReturnOptions Gas options for the return call (B -> A)
     * @param _payInLzToken Boolean flag indicating whether to pay in LZ token
     * @return fee The estimated messaging fee for the A->B leg
     */
    function quote(
        uint32 _dstEid,
        uint16 _msgType,
        string memory _message,
        bytes calldata _extraSendOptions,
        bytes calldata _extraReturnOptions,
        bool _payInLzToken
    ) public view returns (MessagingFee memory fee) {
        // Encode the full message payload
        bytes memory payload = encodeMessage(_message, _msgType, _extraReturnOptions);
        // Combine enforced options with caller-provided options
        bytes memory options = combineOptions(_dstEid, _msgType, _extraSendOptions);
        // Get the quote from LayerZero
        fee = _quote(_dstEid, payload, options, _payInLzToken);
    }

    /**
     * @notice Sends a message to a specified destination chain
     * @dev For ABA messages, ensure msg.value covers both A->B and B->A costs
     * @param _dstEid Destination endpoint ID for the message
     * @param _msgType The type of message to send (SEND or SEND_ABA)
     * @param _message The message content (max 32 bytes)
     * @param _extraSendOptions Gas options for A->B message execution
     * @param _extraReturnOptions Gas options for B->A return message execution
     */
    function send(
        uint32 _dstEid,
        uint16 _msgType,
        string memory _message,
        bytes calldata _extraSendOptions, // gas settings for A -> B
        bytes calldata _extraReturnOptions // gas settings for B -> A (embedded in message)
    ) external payable {
        // Validate message length to prevent excessive gas usage
        require(bytes(_message).length <= 32, "String exceeds 32 bytes");
        
        // Validate message type
        if (_msgType != SEND && _msgType != SEND_ABA) {
            revert InvalidMsgType();
        }
        
        // Combine enforced options (set by owner) with caller options
        bytes memory options = combineOptions(_dstEid, _msgType, _extraSendOptions);

        // Send the cross-chain message via LayerZero
        _lzSend(
            _dstEid,
            encodeMessage(_message, _msgType, _extraReturnOptions), // Encoded payload
            options,                                                // Combined execution options
            MessagingFee(msg.value, 0),                            // Fee in native gas, no ZRO
            payable(msg.sender)                                     // Refund excess gas to caller
        );

        emit MessageSent(_message, _dstEid);
    }

    /**
     * @notice Decodes an encoded message to extract its components
     * @dev Helper function to extract message parts for processing
     * @param encodedMessage The encoded message bytes
     * @return message The original message content
     * @return msgType The message type (SEND or SEND_ABA)
     * @return extraOptionsStart Starting byte position of return options
     * @return extraOptionsLength Length of the return options in bytes
     */
    function decodeMessage(bytes calldata encodedMessage) public pure returns (string memory message, uint16 msgType, uint256 extraOptionsStart, uint256 extraOptionsLength) {
        // The return options start after the first three fields (message, msgType, length)
        extraOptionsStart = 256;  // Starting offset after _message, _msgType, and extraOptionsLength
        string memory _message;
        uint16 _msgType;

        // Decode the first part of the message to get the length
        (_message, _msgType, extraOptionsLength) = abi.decode(encodedMessage, (string, uint16, uint256));
        
        return (_message, _msgType, extraOptionsStart, extraOptionsLength);
    }
    
    /**
     * @notice Internal function to handle receiving messages from another chain
     * @dev This is called by LayerZero when a message arrives. For SEND_ABA messages,
     *      it automatically sends a response back to the origin chain using the embedded options.
     * @param _origin Data about the origin of the received message (srcEid, sender, nonce)
     * @param message The received message content (encoded)
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 /*guid*/,           // Global unique identifier for this message
        bytes calldata message,     // The encoded message payload
        address,                    // Executor address as specified by the OApp
        bytes calldata              // Any extra data or options to trigger on receipt
    ) internal override {

        // Decode the incoming message to extract components
        (string memory _data, uint16 _msgType, uint256 extraOptionsStart, uint256 extraOptionsLength) = decodeMessage(message);
        
        // Store the received message
        data = _data;
        
        // If this is an ABA message, automatically send a response back
        if (_msgType == SEND_ABA) {
            // Create the response message
            string memory _newMessage = "Chain B says goodbye!";

            // Extract the return options that were embedded in the original message
            bytes memory _options = combineOptions(_origin.srcEid, SEND, message[extraOptionsStart:extraOptionsStart + extraOptionsLength]);

            // Send the response back to the origin chain
            _lzSend(
                _origin.srcEid,                         // Send back to origin chain
                abi.encode(_newMessage, SEND),          // Encode response (SEND type, no further response)
                _options,                               // Use the embedded return options
                MessagingFee(msg.value, 0),            // Use forwarded gas for return message
                payable(address(this))                  // Contract receives any refund
            );

            emit ReturnMessageSent(_newMessage, _origin.srcEid);
        }
           
        emit MessageReceived(data, _origin.srcEid, _origin.sender);
    }

    /**
     * @notice Allows the contract to receive native tokens
     * @dev Required for receiving gas refunds and handling return message payments
     */
    receive() external payable {}
}