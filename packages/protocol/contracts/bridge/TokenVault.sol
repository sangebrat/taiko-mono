// SPDX-License-Identifier: MIT
//
// ╭━━━━╮╱╱╭╮╱╱╱╱╱╭╮╱╱╱╱╱╭╮
// ┃╭╮╭╮┃╱╱┃┃╱╱╱╱╱┃┃╱╱╱╱╱┃┃
// ╰╯┃┃┣┻━┳┫┃╭┳━━╮┃┃╱╱╭━━┫╰━┳━━╮
// ╱╱┃┃┃╭╮┣┫╰╯┫╭╮┃┃┃╱╭┫╭╮┃╭╮┃━━┫
// ╱╱┃┃┃╭╮┃┃╭╮┫╰╯┃┃╰━╯┃╭╮┃╰╯┣━━┃
// ╱╱╰╯╰╯╰┻┻╯╰┻━━╯╰━━━┻╯╰┻━━┻━━╯
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/Create2Upgradeable.sol";

import "../common/EssentialContract.sol";
import "../L1/TkoToken.sol";
import "./BridgedERC20.sol";
import "./IBridge.sol";
import "./ITokenVault.sol";

/**
 *  @dev This vault holds all ERC20 tokens (but not Ether) that users have deposited.
 *       It also manages the mapping between cannonical ERC20 tokens and their bridged tokens.
 */
contract TokenVault is EssentialContract, ITokenVault {
    using SafeERC20Upgradeable for ERC20Upgradeable;

    /*********************
     * Structs           *
     *********************/

    struct CannonicalERC20 {
        uint256 chainId;
        address addr;
        uint8 decimals;
        string symbol;
        string name;
    }

    /*********************
     * State Variables   *
     *********************/

    // Tracks if a token on the current chain is a cannoical token or a bridged token.
    mapping(address => bool) public isBridgedToken;

    // Mappings from bridged tokens to their cannonical tokens.
    mapping(address => CannonicalERC20) public bridgedToCanonical;

    // Mappings from canonical tokens to their bridged tokens.
    // chainId => cannonical address => bridged address
    mapping(uint256 => mapping(address => address)) public canonicalToBridged;

    uint256[47] private __gap;

    /*********************
     * Events            *
     *********************/

    event BridgedERC20Deployed(
        uint256 indexed srcChainId,
        address indexed canonicalToken,
        address indexed bridgedToken,
        string canonicalTokenSymbol,
        string canonicalTokenName,
        uint8 canonicalTokenDecimal
    );

    event EtherSent(
        address indexed to,
        uint256 destChainId,
        uint256 amount,
        bytes32 mhash
    );

    event EtherReceived(address from, uint256 amount);

    event ERC20Sent(
        address indexed to,
        uint256 destChainId,
        address token,
        uint256 amount,
        bytes32 mhash
    );

    event ERC20Received(
        address indexed to,
        address from,
        uint256 srcChainId,
        address token,
        uint256 amount
    );

    /*********************
     * External Functions*
     *********************/

    function init(address addressManager) external initializer {
        EssentialContract._init(addressManager);
    }

    /**
     * @dev Sends Ether to the 'to' address on the destChain.
     * Generates a Message struct with the parameters provided
     * and msg attributes, then sends it to the corresponding
     * Bridge.
     * Emits corresponding event
     */
    function sendEther(
        uint256 destChainId,
        address to,
        uint256 gasLimit,
        uint256 maxProcessingFee,
        address refundAddress,
        string memory memo
    ) external payable nonReentrant {
        require(
            to != address(0) && to != resolve(destChainId, "token_vault"),
            "V:to"
        );
        require(msg.value > 0, "V:msgValue");

        IBridge.Message memory message;
        message.destChainId = destChainId;
        message.owner = msg.sender;
        message.to = to;

        message.gasLimit = gasLimit;
        message.maxProcessingFee = maxProcessingFee;
        message.depositValue = msg.value;
        message.refundAddress = refundAddress;
        message.memo = memo;

        // Ether are held by the Bridge, not the TokenVault
        bytes32 mhash = IBridge(resolve("bridge")).sendMessage{
            value: msg.value
        }(message);

        emit EtherSent(to, destChainId, msg.value, mhash);
    }

    // Emits event when this contract receives ether.
    receive() external payable {
        emit EtherReceived(msg.sender, msg.value);
    }

    /// @inheritdoc ITokenVault
    /**
     * @dev Sends ERC20 Tokens to the 'to' address on the destChain.
     * If it is a bridged token, it is directly burned from the user's
     * account on srcChain and the corresponding amount is sent in
     * a message to destChain bridge.
     * If it is canonical, this step is skipped.
     * If it is TkoToken, we burn and mint like Bridged Tokens.
     * Emits corresponding event.
     */
    function sendERC20(
        uint256 destChainId,
        address to,
        address token,
        uint256 amount,
        uint256 gasLimit,
        uint256 maxProcessingFee,
        address refundAddress,
        string memory memo
    ) external payable nonReentrant {
        require(
            to != address(0) && to != resolve(destChainId, "token_vault"),
            "V:to"
        );
        require(token != address(0), "V:token");
        require(amount > 0, "V:amount");

        CannonicalERC20 memory canonicalToken;
        uint256 _amount;

        if (isBridgedToken[token]) {
            BridgedERC20(token).bridgeBurnFrom(msg.sender, amount);
            canonicalToken = bridgedToCanonical[token];
            require(canonicalToken.addr != address(0), "V:canonicalToken");
            _amount = amount;
        } else {
            // The canonical token lives on this chain
            ERC20Upgradeable t = ERC20Upgradeable(token);
            canonicalToken = CannonicalERC20({
                chainId: block.chainid,
                addr: token,
                decimals: t.decimals(),
                symbol: t.symbol(),
                name: t.name()
            });

            if (token == resolve("tko_token")) {
                // Special handling for Tai token: we do not send TAI to
                // this vault, instead, we burn the user's TAI. This is because
                // on L2, we are minting new tokens to validators and DAO.
                TkoToken(token).burn(msg.sender, amount);
                _amount = amount;
            } else {
                uint256 _balance = t.balanceOf(address(this));
                t.safeTransferFrom(msg.sender, address(this), amount);
                _amount = t.balanceOf(address(this)) - _balance;
            }
        }

        IBridge.Message memory message;
        message.destChainId = destChainId;
        message.owner = msg.sender;

        message.to = resolve(destChainId, "token_vault");
        message.data = abi.encodeWithSelector(
            TokenVault.receiveERC20.selector,
            canonicalToken,
            message.owner,
            to,
            _amount
        );

        message.gasLimit = gasLimit;
        message.maxProcessingFee = maxProcessingFee;
        message.depositValue = msg.value;
        message.refundAddress = refundAddress;
        message.memo = memo;

        bytes32 mhash = IBridge(resolve("bridge")).sendMessage{
            value: msg.value
        }(message);

        emit ERC20Sent(to, destChainId, token, _amount, mhash);
    }

    /**
     * @dev This function can only be called by the bridge contract while invoking
     *      a message call.
     * @param canonicalToken The cannonical ERC20 token which may or may not live
     *        on this chain. If not, a BridgedERC20 contract will be deployed.
     * @param from The source address.
     * @param to The destination address.
     * @param amount The amount of tokens to be sent. 0 is a valid value.
     */
    function receiveERC20(
        CannonicalERC20 calldata canonicalToken,
        address from,
        address to,
        uint256 amount
    ) external nonReentrant onlyFromNamed("bridge") {
        IBridge.Context memory ctx = IBridge(msg.sender).context();
        require(
            ctx.sender == resolve(ctx.srcChainId, "token_vault"),
            "V:sender"
        );

        address token;
        if (canonicalToken.chainId == block.chainid) {
            token = canonicalToken.addr;
            if (token == resolve("tko_token")) {
                // Special handling for Tai token: we do not send TAI from
                // this vault to the user, instead, we mint new TAI to him.
                TkoToken(token).mint(to, amount);
            } else {
                ERC20Upgradeable(token).safeTransfer(to, amount);
            }
        } else {
            token = _getOrDeployBridgedToken(canonicalToken);
            BridgedERC20(token).bridgeMintTo(to, amount);
        }

        emit ERC20Received(to, from, ctx.srcChainId, token, amount);
    }

    /*********************
     * Private Functions *
     *********************/

    function _getOrDeployBridgedToken(CannonicalERC20 calldata canonicalToken)
        private
        returns (address)
    {
        address token = canonicalToBridged[canonicalToken.chainId][
            canonicalToken.addr
        ];

        return
            token != address(0) ? token : _deployBridgedToken(canonicalToken);
    }

    function _deployBridgedToken(CannonicalERC20 calldata canonicalToken)
        private
        returns (address bridgedToken)
    {
        bytes32 salt = keccak256(
            abi.encodePacked(canonicalToken.chainId, canonicalToken.addr)
        );
        bridgedToken = Create2Upgradeable.deploy(
            0, // amount of Ether to send
            salt,
            type(BridgedERC20).creationCode
        );

        BridgedERC20(payable(bridgedToken)).init(
            address(_addressManager),
            canonicalToken.addr,
            canonicalToken.chainId,
            canonicalToken.decimals,
            canonicalToken.symbol,
            string(
                abi.encodePacked(
                    canonicalToken.name,
                    "(bridged",
                    hex"F09F8C88", // 🌈
                    canonicalToken.chainId,
                    ")"
                )
            )
        );

        isBridgedToken[bridgedToken] = true;

        bridgedToCanonical[bridgedToken] = canonicalToken;

        canonicalToBridged[canonicalToken.chainId][
            canonicalToken.addr
        ] = bridgedToken;

        emit BridgedERC20Deployed(
            canonicalToken.chainId,
            canonicalToken.addr,
            bridgedToken,
            canonicalToken.symbol,
            canonicalToken.name,
            canonicalToken.decimals
        );
    }
}
