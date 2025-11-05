// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title Authorizer
 * @notice EIP-712 based authorization contract for presale vouchers
 * @dev Validates cryptographically signed vouchers from backend with nonce consumption
 */
contract Authorizer is Ownable, EIP712 {
    using ECDSA for bytes32;

    // ============ STRUCTS ============

    /// @notice Structure of a purchase voucher
    struct Voucher {
        address buyer;          // Wallet address authorized to purchase
        address beneficiary;    // Address that will receive the tokens
        address paymentToken;   // Allowed payment token (address(0) for native)
        uint256 usdLimit;      // Maximum purchase amount in USD (8 decimals)
        uint256 nonce;         // Unique nonce to prevent replay
        uint256 deadline;      // Expiration timestamp
        address presale;       // Specific presale contract address
    }

    // ============ CONSTANTS ============

    /// @notice EIP-712 typehash for Voucher struct
    bytes32 private constant VOUCHER_TYPEHASH = keccak256(
        "Voucher(address buyer,address beneficiary,address paymentToken,uint256 usdLimit,uint256 nonce,uint256 deadline,address presale)"
    );

    // ============ STATE VARIABLES ============

    /// @notice Backend signer address that issues vouchers
    address public signer;

    /// @notice Mapping of user address to their current nonce
    mapping(address => uint256) public nonces;

    /// @notice Mapping to track consumed voucher hashes
    mapping(bytes32 => bool) public consumedVouchers;

    // ============ EVENTS ============

    /// @notice Emitted when signer address is updated
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);

    /// @notice Emitted when a voucher is consumed
    event VoucherConsumed(address indexed buyer, uint256 nonce, bytes32 voucherHash);

    /// @notice Emitted when authorization fails
    event AuthorizationFailed(address indexed buyer, string reason);

    // ============ ERRORS ============

    error InvalidSigner();
    error VoucherExpired();
    error InvalidPresaleAddress();
    error InvalidPaymentToken();
    error InsufficientLimit();
    error InvalidNonce();
    error VoucherAlreadyConsumed();
    error InvalidSignature();
    error ZeroAddress();

    // ============ CONSTRUCTOR ============

    /// @notice Initialize the Authorizer contract
    /// @param _signer Backend signer address
    /// @param _owner Contract owner address
    constructor(
        address _signer,
        address _owner
    ) EIP712("EscrowAuthorizer", "1") Ownable(_owner) {
        if (_signer == address(0) || _owner == address(0)) revert ZeroAddress();
        
        signer = _signer;

        emit SignerUpdated(address(0), _signer);
    }

    // ============ AUTHORIZATION FUNCTIONS ============

    /// @notice Authorizes a purchase by validating and consuming a voucher
    /// @param voucher The purchase voucher containing authorization details
    /// @param signature EIP-712 signature of the voucher
    /// @param paymentToken Token being used for payment
    /// @param usdAmount USD amount being purchased (8 decimals)
    /// @return True if authorization successful
    function authorize(
        Voucher calldata voucher,
        bytes calldata signature,
        address paymentToken,
        uint256 usdAmount
    ) external returns (bool) {
        // Basic validations
        if (block.timestamp > voucher.deadline) {
            emit AuthorizationFailed(voucher.buyer, "Voucher expired");
            revert VoucherExpired();
        }

        // if (voucher.presale != msg.sender) {
        //     emit AuthorizationFailed(voucher.buyer, "Invalid presale address");
        //     revert InvalidPresaleAddress();
        // }

        if (voucher.paymentToken != paymentToken) {
            emit AuthorizationFailed(voucher.buyer, "Invalid payment token");
            revert InvalidPaymentToken();
        }

        if (usdAmount > voucher.usdLimit) {
            emit AuthorizationFailed(voucher.buyer, "Insufficient limit");
            revert InsufficientLimit();
        }

        if (voucher.nonce != nonces[voucher.buyer]) {
            emit AuthorizationFailed(voucher.buyer, "Invalid nonce");
            revert InvalidNonce();
        }

        // Generate voucher hash for consumption tracking
        bytes32 voucherHash = _hashVoucher(voucher);
        
        if (consumedVouchers[voucherHash]) {
            emit AuthorizationFailed(voucher.buyer, "Voucher already consumed");
            revert VoucherAlreadyConsumed();
        }

        // Verify EIP-712 signature
        bytes32 digest = _hashTypedDataV4(voucherHash);
        address recoveredSigner = digest.recover(signature);
        
        if (recoveredSigner != signer) {
            emit AuthorizationFailed(voucher.buyer, "Invalid signature");
            revert InvalidSignature();
        }

        // Consume voucher
        consumedVouchers[voucherHash] = true;
        nonces[voucher.buyer]++;

        emit VoucherConsumed(voucher.buyer, voucher.nonce, voucherHash);
        return true;
    }

    /// @notice Validates a voucher without consuming it (view function)
    /// @param voucher The purchase voucher to validate
    /// @param signature EIP-712 signature of the voucher
    /// @param paymentToken Token being used for payment
    /// @param usdAmount USD amount being purchased (8 decimals)
    /// @return valid True if voucher is valid
    /// @return reason Reason for invalidity (empty if valid)
    function validateVoucher(
        Voucher calldata voucher,
        bytes calldata signature,
        address paymentToken,
        uint256 usdAmount
    ) external view returns (bool valid, string memory reason) {
        // Check expiration
        if (block.timestamp > voucher.deadline) {
            return (false, "Voucher expired");
        }

        // // Check presale address
        // if (voucher.presale != msg.sender) {
        //     return (false, "Invalid presale address");
        // }

        // Check payment token
        if (voucher.paymentToken != paymentToken) {
            return (false, "Invalid payment token");
        }

        // Check USD limit
        if (usdAmount > voucher.usdLimit) {
            return (false, "Insufficient limit");
        }

        // Check nonce
        if (voucher.nonce != nonces[voucher.buyer]) {
            return (false, "Invalid nonce");
        }

        // Check if already consumed
        bytes32 voucherHash = _hashVoucher(voucher);
        if (consumedVouchers[voucherHash]) {
            return (false, "Voucher already consumed");
        }

        // Verify signature
        bytes32 digest = _hashTypedDataV4(voucherHash);
        address recoveredSigner = digest.recover(signature);
        
        if (recoveredSigner != signer) {
            return (false, "Invalid signature");
        }

        return (true, "");
    }


    /////////////////////////////////////////

    function validateVoucherOriginal(
        Voucher calldata voucher,
        bytes calldata signature,
        address paymentToken,
        uint256 usdAmount
    ) external view returns (bool valid, string memory reason) {
        // Check expiration
        if (block.timestamp > voucher.deadline) {
            return (false, "Voucher expired");
        }

        // Check presale address
        if (voucher.presale != msg.sender) {
            return (false, "Invalid presale address");
        }

        // Check payment token
        if (voucher.paymentToken != paymentToken) {
            return (false, "Invalid payment token");
        }

        // Check USD limit
        if (usdAmount > voucher.usdLimit) {
            return (false, "Insufficient limit");
        }

        // Check nonce
        if (voucher.nonce != nonces[voucher.buyer]) {
            return (false, "Invalid nonce");
        }

        // Check if already consumed
        bytes32 voucherHash = _hashVoucher(voucher);
        if (consumedVouchers[voucherHash]) {
            return (false, "Voucher already consumed");
        }

        // Verify signature
        bytes32 digest = _hashTypedDataV4(voucherHash);
        address recoveredSigner = digest.recover(signature);
        
        if (recoveredSigner != signer) {
            return (false, "Invalid signature");
        }

        return (true, "");
    }

    // ============ ADMIN FUNCTIONS ============

    /// @notice Updates the backend signer address
    /// @param _newSigner New signer address
    function setSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert ZeroAddress();
        
        address oldSigner = signer;
        signer = _newSigner;
        
        emit SignerUpdated(oldSigner, _newSigner);
    }

    /// @notice Emergency function to invalidate a specific voucher
    /// @param voucher The voucher to invalidate
    function invalidateVoucher(Voucher calldata voucher) external onlyOwner {
        bytes32 voucherHash = _hashVoucher(voucher);
        consumedVouchers[voucherHash] = true;
        
        emit VoucherConsumed(voucher.buyer, voucher.nonce, voucherHash);
    }

    // ============ VIEW FUNCTIONS ============

    /// @notice Gets the current nonce for a user
    /// @param user User address
    /// @return Current nonce
    function getNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /// @notice Checks if a voucher hash has been consumed
    /// @param voucherHash Hash of the voucher
    /// @return True if consumed
    function isVoucherConsumed(bytes32 voucherHash) external view returns (bool) {
        return consumedVouchers[voucherHash];
    }

    /// @notice Gets the EIP-712 domain separator
    /// @return Domain separator hash
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ============ INTERNAL FUNCTIONS ============

    /// @notice Hashes a voucher according to EIP-712
    /// @param voucher The voucher to hash
    /// @return Voucher hash
    function _hashVoucher(Voucher calldata voucher) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            VOUCHER_TYPEHASH,
            voucher.buyer,
            voucher.beneficiary,
            voucher.paymentToken,
            voucher.usdLimit,
            voucher.nonce,
            voucher.deadline,
            voucher.presale
        ));
    }
}