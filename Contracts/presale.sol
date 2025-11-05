// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "./Authorizer.sol";

/**
 * @title MultiTokenPresale
 * @notice Advanced presale contract with KYC voucher authorization system
 * @dev Implements strict beneficiary validation through cryptographic vouchers:
 * - UnityPresaleV2.sol: Enforces beneficiary == msg.sender (no delegated purchases)
 * - MultiTokenPresale.sol: Allows delegated purchases ONLY through authorized vouchers
 * - This ensures consistent validation across the presale system
 * 
 */
contract MultiTokenPresale is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    
    // GRO-02: Hardcoded owner/treasury address (hardware wallet)
    // Security rationale: 1 hardware wallet > 2-of-3 multisig with hot wallets
    // - Hardware wallet keys never exposed to internet (physical 2FA)
    // - Multisig with 2 hot wallets = increased attack surface
    // - If 2 multisig keys lost = funds lost forever
    address public constant OWNER_ADDRESS = 0xd81d23f2e37248F8fda5e7BF0a6c047AE234F0A2;
    
    // Token price structure
    struct TokenPrice {
        uint256 priceUSD;        // Price in USD (8 decimals)
        bool isActive;           // Whether this token is accepted
        uint8 decimals;          // Token decimals
    }
    
    // Presale token details
    IERC20 public presaleToken;
    uint256 public immutable presaleRate;  // Tokens per USD (18 decimals)
    uint256 public immutable maxTokensToMint;
    uint256 public totalTokensMinted;
    
    // Authorizer integration for voucher-based purchases
    Authorizer public authorizer;
    bool public voucherSystemEnabled = false; // Disabled by default for compatibility
    
    // Treasury / beneficiary wallet
    address public treasury;
    address public pendingTreasury;
    
    // Dev treasury - incentives for developers who contributed to this project (receives 4% fee)
    address public immutable devTreasury;
    
    // GRO-06 Fix: Fixed gas buffer (not tx.gasprice dependent)
    uint256 public gasBuffer = 0.0005 ether; // Default 0.0005 ETH buffer
    
    // Price management
    mapping(address => TokenPrice) public tokenPrices;
    
    // User tracking
    mapping(address => mapping(address => uint256)) public purchasedAmounts; // user => token => amount
    mapping(address => uint256) public totalPurchased; // Total tokens purchased by user
    mapping(address => uint256) public totalUsdPurchased; // User's cumulative USD spent (8 decimals)
    mapping(address => bool) public hasClaimed;
    
    // GRO-19: In-contract replay protection (defense-in-depth)
    mapping(bytes32 => bool) private usedVoucherHashes; // Track consumed voucher hashes independently
    
    // Presale timing controls (for manual startPresale)
    uint256 public presaleStartTime;
    uint256 public presaleEndTime;
    bool public presaleEnded;
    
    // Escrow presale timing controls (for autoStartIEscrowPresale)
    uint256 public escrowPresaleStartTime;
    uint256 public escrowPresaleEndTime;
    bool public escrowPresaleEnded;
    
    // Scheduled launch and two rounds
    uint256 public constant PRESALE_LAUNCH_DATE = 1762819200; // Nov 11, 2025 00:00 UTC
    uint256 public constant MAX_PRESALE_DURATION = 34 days;
    uint256 public constant ROUND1_DURATION = 23 days;
    uint256 public constant ROUND2_DURATION = 11 days;
    
    // Main presale round management
    uint256 public currentRound = 0; // 0 = not started, 1 = round 1, 2 = round 2
    uint256 public round1EndTime;
    uint256 public round1TokensSold;
    uint256 public round2TokensSold;
    
    // Escrow presale round management
    uint256 public escrowCurrentRound = 0; // 0 = not started, 1 = round 1, 2 = round 2
    uint256 public escrowRound1EndTime;
    uint256 public escrowRound1TokensSold;
    uint256 public escrowRound2TokensSold;
    
    // Constants
    address public constant NATIVE_ADDRESS = address(0); // ETH on Ethereum
    uint256 public constant USD_DECIMALS = 8;
    
    // Ethereum Mainnet Token Addresses
    address public constant WETH_ADDRESS = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant WBNB_ADDRESS = 0x418D75f65a02b3D53B2418FB8E1fe493759c7605;
    address public constant LINK_ADDRESS = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address public constant WBTC_ADDRESS = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address public constant USDC_ADDRESS = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USDT_ADDRESS = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    
    // Events
    event TokenPurchase(
        address indexed purchaser,
        address indexed beneficiary,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 tokenAmount
    );
    
    event TokensClaimed(address indexed user, uint256 amount);
    event PriceUpdated(address indexed token, uint256 newPrice);
    event TokenStatusUpdated(address indexed token, bool isActive);
    event PresaleStarted(uint256 startTime, uint256 endTime);
    event PresaleEnded(uint256 endTime);
    event PresaleEndedEarly(string reason, uint256 endTime);
    event RoundAdvanced(uint256 fromRound, uint256 toRound, uint256 timestamp);
    event EmergencyEnd(uint256 timestamp);
    event AutoStartTriggered(uint256 timestamp);
    event GasBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event MaxPurchasePerUserUpdated(uint256 oldMax, uint256 newMax);
    event AuthorizerUpdated(address indexed oldAuthorizer, address indexed newAuthorizer);
    event VoucherSystemToggled(bool enabled);
    event VoucherPurchase(
        address indexed purchaser,
        address indexed beneficiary,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 tokenAmount,
        bytes32 voucherHash
    );
    event VoucherHashConsumed(bytes32 indexed voucherHash, address indexed buyer);
    event TreasuryUpdateRequested(address indexed newTreasury);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    
    constructor(
        address _presaleToken,
        uint256 _presaleRate, // 0.0015 dollar per token => 666.666... tokens per USD with 18 decimals: ~666666666666666667000
        uint256 _maxTokensToMint, // 5 billion tokens to presale
        address _devTreasury // Dev treasury address for 4% fee (immutable)
    ) Ownable(OWNER_ADDRESS) {
        require(_presaleToken != address(0), "Invalid presale token");
        require(_presaleRate > 0, "Invalid presale rate");
        require(_maxTokensToMint > 0, "Invalid max tokens");
        require(_devTreasury != address(0), "Invalid dev treasury");
        
        presaleToken = IERC20(_presaleToken);
        presaleRate = _presaleRate;
        maxTokensToMint = _maxTokensToMint;
        
        // Initialize default token prices and limits
        _initializeDefaultTokens();
        
        // GRO-02: Treasury is same as owner (hardcoded hardware wallet)
        treasury = OWNER_ADDRESS;
        
        // Dev treasury for 4% fee (set in constructor, immutable)
        devTreasury = _devTreasury;
    }
    
    // ============ MODIFIERS ============
    // GRO-02: All sensitive functions restricted to owner (hardware wallet)
    modifier onlyGovernance() {
        require(msg.sender == owner(), "Only owner");
        _;
    }

    /// @notice Propose a new treasury address that will custody withdrawn funds.
    function proposeTreasury(address newTreasury) external onlyGovernance {
        require(newTreasury != address(0), "Invalid treasury");

        pendingTreasury = newTreasury;
        emit TreasuryUpdateRequested(newTreasury);
    }

    /// @notice Accept the treasury role.
    function acceptTreasury() external {
        require(msg.sender == pendingTreasury, "Caller not pending treasury");

        address previousTreasury = treasury;
        treasury = pendingTreasury;
        pendingTreasury = address(0);

        emit TreasuryUpdated(previousTreasury, treasury);
    }
    
    // Initialize default token settings for UnityFinance presale
    function _initializeDefaultTokens() internal {
        // ETH (Native) - $4200, 18 decimals, per-token cap disabled (use global cap)
        tokenPrices[NATIVE_ADDRESS] = TokenPrice({
            priceUSD: 4200 * 1e8,  // $4200
            isActive: true,
            decimals: 18
        });
        
        // WETH - $4200, 18 decimals, per-token cap disabled (use global cap)
        tokenPrices[WETH_ADDRESS] = TokenPrice({
            priceUSD: 4200 * 1e8,  // $4200
            isActive: true,
            decimals: 18
        });

        // WBNB - $1000, 18 decimals, per-token cap disabled (use global cap)
        tokenPrices[WBNB_ADDRESS] = TokenPrice({
            priceUSD: 1000 * 1e8,   // $1000
            isActive: true,
            decimals: 18
        });
        
        
        // LINK - $20, 18 decimals, per-token cap disabled (use global cap)
        tokenPrices[LINK_ADDRESS] = TokenPrice({
            priceUSD: 20 * 1e8,    // $20
            isActive: true,
            decimals: 18
        });        
        // WBTC - $45000, 8 decimals, per-token cap disabled (use global cap)
        tokenPrices[WBTC_ADDRESS] = TokenPrice({
            priceUSD: 45000 * 1e8, // $45000
            isActive: true,
            decimals: 8
        });
        
        // USDC - $1, 6 decimals, per-token cap disabled (use global cap)
        tokenPrices[USDC_ADDRESS] = TokenPrice({
            priceUSD: 1 * 1e8,     // $1
            isActive: true,
            decimals: 6
        });
        
        // USDT - $1, 6 decimals, per-token cap disabled (use global cap)
        tokenPrices[USDT_ADDRESS] = TokenPrice({
            priceUSD: 1 * 1e8,     // $1
            isActive: true,
            decimals: 6
        });
        
    }
    
    // ============ PRICE MANAGEMENT ============
    
    function setTokenPrice(
        address token,
        uint256 priceUSD,
        uint8 decimals,
        bool isActive
    ) external onlyGovernance {
        require(priceUSD > 0, "Invalid price");
        require(decimals <= 18, "Invalid decimals");
        // Prevent price changes during active rounds (both main and escrow presales)
        bool mainPresaleActive = presaleStartTime > 0 && !presaleEnded && block.timestamp <= presaleEndTime;
        bool escrowPresaleActive = escrowPresaleStartTime > 0 && !escrowPresaleEnded && block.timestamp <= escrowPresaleEndTime;
        require(!mainPresaleActive && !escrowPresaleActive, "Cannot change prices during active presale");
        
        tokenPrices[token] = TokenPrice({
            priceUSD: priceUSD,
            isActive: isActive,
            decimals: decimals
        });
        
        emit PriceUpdated(token, priceUSD);
        emit TokenStatusUpdated(token, isActive);
    }
    
    /// @notice Set multiple token prices atomically (only when no presale is active)
    function setTokenPrices(
        address[] calldata tokens,
        uint256[] calldata pricesUSD,
        uint8[] calldata decimalsArray,
        bool[] calldata activeArray
    ) external onlyGovernance {
        require(tokens.length == pricesUSD.length, "Array length mismatch");
        require(tokens.length == decimalsArray.length, "Array length mismatch");
        require(tokens.length == activeArray.length, "Array length mismatch");
        require(tokens.length > 0, "Empty arrays");
        // Prevent price changes during active presales (both main and escrow presales)
        bool mainPresaleActive = presaleStartTime > 0 && !presaleEnded && block.timestamp <= presaleEndTime;
        bool escrowPresaleActive = escrowPresaleStartTime > 0 && !escrowPresaleEnded && block.timestamp <= escrowPresaleEndTime;
        require(!mainPresaleActive && !escrowPresaleActive, "Cannot change prices during active presale");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            require(pricesUSD[i] > 0, "Invalid price");
            require(decimalsArray[i] <= 18, "Invalid decimals");
            
            tokenPrices[tokens[i]] = TokenPrice({
                priceUSD: pricesUSD[i],
                isActive: activeArray[i],
                decimals: decimalsArray[i]
            });
            
            emit PriceUpdated(tokens[i], pricesUSD[i]);
            emit TokenStatusUpdated(tokens[i], activeArray[i]);
        }
    }
    
    // Presale timing controls
    function startPresale(uint256 _duration) external onlyGovernance {
        require(presaleStartTime == 0, "Presale already started");
        require(!presaleEnded, "Presale already ended - cannot restart");
        require(_duration == MAX_PRESALE_DURATION, "Duration must match schedule");
        require(
            presaleToken.balanceOf(address(this)) >= maxTokensToMint,
            "Insufficient presale tokens in contract"
        );

        presaleStartTime = block.timestamp;
        round1EndTime = block.timestamp + ROUND1_DURATION;
        presaleEndTime = block.timestamp + _duration;
        currentRound = 1;
        presaleEnded = false;

        emit PresaleStarted(presaleStartTime, presaleEndTime);
        _handleRoundTransition(0, 1);
    }
    
    // Auto-start presale on November 11, 2025 - Anyone can trigger
    function autoStartIEscrowPresale() external {
        require(escrowPresaleStartTime == 0, "Escrow presale already started");
        require(!escrowPresaleEnded, "Escrow presale already ended - cannot restart");
        require(block.timestamp >= PRESALE_LAUNCH_DATE, "Too early - presale starts Nov 11, 2025");
        
        // Verify contract has enough presale tokens (5B $ESCROW)
        uint256 contractBalance = presaleToken.balanceOf(address(this));
        require(contractBalance >= maxTokensToMint, "Insufficient presale tokens in contract");
        
        // Start Escrow Presale Round 1
        escrowPresaleStartTime = block.timestamp;
        escrowRound1EndTime = block.timestamp + ROUND1_DURATION;
        escrowPresaleEndTime = block.timestamp + MAX_PRESALE_DURATION;
        escrowCurrentRound = 1;
        escrowPresaleEnded = false;
        
        emit PresaleStarted(escrowPresaleStartTime, escrowPresaleEndTime);
        emit AutoStartTriggered(block.timestamp);
        emit RoundAdvanced(0, 1, block.timestamp);
    }
    
    function endPresale() external onlyGovernance {
        require(presaleStartTime > 0, "Presale not started");
        require(!presaleEnded, "Presale already ended");
        if(block.timestamp < presaleEndTime) revert("Presale not ended yet");
        presaleEnded = true;
        presaleEndTime = block.timestamp;
        emit PresaleEnded(presaleEndTime);
    }
    
    function extendPresale(uint256 _additionalDuration) external onlyGovernance {
        require(presaleStartTime > 0, "Presale not started");
        require(!presaleEnded, "Presale already ended");
        require(_additionalDuration <= 7 days, "Cannot extend more than 7 days");
        uint256 newEnd = presaleEndTime + _additionalDuration;
        require(
            newEnd <= presaleStartTime + MAX_PRESALE_DURATION,
            "Cannot extend beyond max duration"
        );
        presaleEndTime = newEnd;
    }
    
    // Emergency end presale immediately
    function emergencyEndPresale() external onlyGovernance {
        require(presaleStartTime > 0, "Presale not started");
        require(!presaleEnded, "Presale already ended");
        
        presaleEnded = true;
        presaleEndTime = block.timestamp;
        
        emit EmergencyEnd(block.timestamp);
        emit PresaleEnded(presaleEndTime);
    }
    
    // End escrow presale
    function endEscrowPresale() external onlyGovernance {
        require(escrowPresaleStartTime > 0, "Escrow presale not started");
        require(!escrowPresaleEnded, "Escrow presale already ended");
        if(block.timestamp < escrowPresaleEndTime) revert("Escrow presale not ended yet");
        escrowPresaleEnded = true;
        escrowPresaleEndTime = block.timestamp;
        emit PresaleEnded(escrowPresaleEndTime);
    }
    
    // Extend escrow presale
    function extendEscrowPresale(uint256 _additionalDuration) external onlyGovernance {
        require(escrowPresaleStartTime > 0, "Escrow presale not started");
        require(!escrowPresaleEnded, "Escrow presale already ended");
        require(_additionalDuration <= 7 days, "Cannot extend more than 7 days");
        uint256 newEnd = escrowPresaleEndTime + _additionalDuration;
        require(
            newEnd <= escrowPresaleStartTime + MAX_PRESALE_DURATION,
            "Cannot extend beyond max duration"
        );
        escrowPresaleEndTime = newEnd;
    }
    
    // Emergency end escrow presale immediately
    function emergencyEndEscrowPresale() external onlyGovernance {
        require(escrowPresaleStartTime > 0, "Escrow presale not started");
        require(!escrowPresaleEnded, "Escrow presale already ended");
        
        escrowPresaleEnded = true;
        escrowPresaleEndTime = block.timestamp;
        
        emit EmergencyEnd(block.timestamp);
        emit PresaleEnded(escrowPresaleEndTime);
    }
    
    // Manually advance from Round 1 to Round 2 with required price updates
    function moveToRound2(
        address[] calldata tokens,
        uint256[] calldata pricesUSD,
        uint8[] calldata decimalsArray,
        bool[] calldata activeArray
    ) external onlyGovernance {
        require(currentRound == 1, "Not in round 1");
        require(!presaleEnded, "Presale already ended");
        require(tokens.length == pricesUSD.length, "Array length mismatch");
        require(tokens.length == decimalsArray.length, "Array length mismatch");
        require(tokens.length == activeArray.length, "Array length mismatch");
        require(tokens.length > 0, "Must provide round 2 prices");
        
        // Set new prices for round 2
        for (uint256 i = 0; i < tokens.length; i++) {
            require(pricesUSD[i] > 0, "Invalid price");
            require(decimalsArray[i] <= 18, "Invalid decimals");
            
            TokenPrice memory oldPrice = tokenPrices[tokens[i]];
            require(oldPrice.priceUSD != pricesUSD[i], "Round 2 price must differ from round 1");
            
            tokenPrices[tokens[i]] = TokenPrice({
                priceUSD: pricesUSD[i],
                isActive: activeArray[i],
                decimals: decimalsArray[i]
            });
            
            emit PriceUpdated(tokens[i], pricesUSD[i]);
            emit TokenStatusUpdated(tokens[i], activeArray[i]);
        }
        
        // Advance to round 2
        currentRound = 2;
        round1EndTime = block.timestamp;
        
        emit RoundAdvanced(1, 2, block.timestamp);
    }
    
    // Manually advance escrow presale from Round 1 to Round 2 with required price updates
    function moveEscrowToRound2(
        address[] calldata tokens,
        uint256[] calldata pricesUSD,
        uint8[] calldata decimalsArray,
        bool[] calldata activeArray
    ) external onlyGovernance {
        require(escrowCurrentRound == 1, "Escrow presale not in round 1");
        require(!escrowPresaleEnded, "Escrow presale already ended");
        require(tokens.length == pricesUSD.length, "Array length mismatch");
        require(tokens.length == decimalsArray.length, "Array length mismatch");
        require(tokens.length == activeArray.length, "Array length mismatch");
        require(tokens.length > 0, "Must provide round 2 prices");
        
        // Set new prices for round 2
        for (uint256 i = 0; i < tokens.length; i++) {
            require(pricesUSD[i] > 0, "Invalid price");
            require(decimalsArray[i] <= 18, "Invalid decimals");
            
            TokenPrice memory oldPrice = tokenPrices[tokens[i]];
            require(oldPrice.priceUSD != pricesUSD[i], "Round 2 price must differ from round 1");
            
            tokenPrices[tokens[i]] = TokenPrice({
                priceUSD: pricesUSD[i],
                isActive: activeArray[i],
                decimals: decimalsArray[i]
            });
            
            emit PriceUpdated(tokens[i], pricesUSD[i]);
            emit TokenStatusUpdated(tokens[i], activeArray[i]);
        }
        
        // Advance escrow presale to round 2
        escrowCurrentRound = 2;
        escrowRound1EndTime = block.timestamp;
        
        emit RoundAdvanced(1, 2, block.timestamp);
    }
    
    /// @notice Emergency function to update prices during round transitions (use with extreme caution)
    /// @dev Only to be used if auto-advancement occurred without price updates
    function emergencyUpdatePrices(
        address[] calldata tokens,
        uint256[] calldata pricesUSD,
        uint8[] calldata decimalsArray,
        bool[] calldata activeArray
    ) external onlyGovernance {
        require(tokens.length == pricesUSD.length, "Array length mismatch");
        require(tokens.length == decimalsArray.length, "Array length mismatch");
        require(tokens.length == activeArray.length, "Array length mismatch");
        require(tokens.length > 0, "Empty arrays");
        // Only allow during active presale for emergency situations
        require(presaleStartTime > 0 && !presaleEnded, "Presale not active");
        
        for (uint256 i = 0; i < tokens.length; i++) {
            require(pricesUSD[i] > 0, "Invalid price");
            require(decimalsArray[i] <= 18, "Invalid decimals");
            
            tokenPrices[tokens[i]] = TokenPrice({
                priceUSD: pricesUSD[i],
                isActive: activeArray[i],
                decimals: decimalsArray[i]
            });
            
            emit PriceUpdated(tokens[i], pricesUSD[i]);
            emit TokenStatusUpdated(tokens[i], activeArray[i]);
        }
    }
    
    // ============ VOUCHER-ONLY PURCHASE FUNCTIONS ============
    // NOTE: All purchases MUST use vouchers (KYC verified off-chain)
    // No direct purchase functions to prevent non-KYC purchases
    
    // ============ VOUCHER-BASED PURCHASE FUNCTIONS ============
    
    /// @notice Purchase with native currency using voucher authorization (KYC-AUTHORIZED DELEGATED PURCHASES)
    /// @dev BENEFICIARY VALIDATION POLICY: Allows delegated purchases ONLY through authorized vouchers
    /// - voucher.buyer must equal msg.sender (only voucher holder can use it)
    /// - voucher.beneficiary must equal beneficiary parameter (specified in voucher)
    /// - This enables KYC-verified delegated purchases while preventing unauthorized ones
    /// @param beneficiary Address that will receive the tokens (must match voucher.beneficiary)
    /// @param voucher Purchase voucher containing authorization details
    /// @param signature EIP-712 signature of the voucher
    function buyWithNativeVoucher(
        address beneficiary,
        Authorizer.Voucher calldata voucher,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused {
        require(voucherSystemEnabled, "Voucher system not enabled");
        require(address(authorizer) != address(0), "Authorizer not set");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(msg.value > 0, "No native currency sent");
        // Check if any presale is active
        uint8 activeMode = _getActivePresaleMode();
        require(activeMode == 1 || activeMode == 2, "No presale active");
        require(activeMode != 3, "Cannot run both presales simultaneously");
        require(voucher.buyer == msg.sender, "Only buyer can use voucher");
        require(voucher.beneficiary == beneficiary, "Beneficiary mismatch");
        require(voucher.paymentToken == NATIVE_ADDRESS, "Invalid payment token");
        
        TokenPrice memory nativePrice = tokenPrices[NATIVE_ADDRESS];
        require(nativePrice.isActive, "Native currency not accepted");
        
        // Apply configured gas buffer (if any) to keep allocation independent from tx.gasprice
        uint256 paymentAmount = _applyGasBuffer(msg.value);
        
        // Calculate USD amount for authorization (8 decimals) - user gets tokens for full amount
        uint256 usdAmount = (paymentAmount * nativePrice.priceUSD) / (10 ** nativePrice.decimals);
        require(usdAmount > 0, "Payment amount too small");
        
        // GRO-19: In-contract replay protection (defense-in-depth)
        bytes32 voucherHash = _computeVoucherHash(voucher);
        require(!usedVoucherHashes[voucherHash], "Voucher already used in this contract");
        
        // Authorize purchase with voucher (external Authorizer)
        bool authorized = authorizer.authorize(voucher, signature, NATIVE_ADDRESS, usdAmount);
        require(authorized, "Voucher authorization failed");
        
        // Mark voucher as used in this contract
        usedVoucherHashes[voucherHash] = true;
        emit VoucherHashConsumed(voucherHash, voucher.buyer);
        
        uint256 tokenAmount = _calculateTokenAmountForVoucher(NATIVE_ADDRESS, paymentAmount, beneficiary, usdAmount);
        require(tokenAmount > 0, "Token amount too small");
        
        // Calculate and transfer 4% fee to dev treasury (using 400/10000 for better precision)
        uint256 devFee = (paymentAmount * 400) / 10000;
        payable(devTreasury).transfer(devFee);
        _processVoucherPurchase(beneficiary, NATIVE_ADDRESS, paymentAmount, tokenAmount, voucher);
    }
    
    /// @notice Purchase with ERC20 tokens using voucher authorization (KYC-AUTHORIZED DELEGATED PURCHASES)
    /// @dev BENEFICIARY VALIDATION POLICY: Allows delegated purchases ONLY through authorized vouchers
    /// - voucher.buyer must equal msg.sender (only voucher holder can use it)
    /// - voucher.beneficiary must equal beneficiary parameter (specified in voucher)
    /// - This enables KYC-verified delegated purchases while preventing unauthorized ones
    /// @param token Payment token address
    /// @param amount Payment token amount
    /// @param beneficiary Address that will receive the tokens (must match voucher.beneficiary)
    /// @param voucher Purchase voucher containing authorization details
    /// @param signature EIP-712 signature of the voucher
    function buyWithTokenVoucher(
        address token,
        uint256 amount,
        address beneficiary,
        Authorizer.Voucher calldata voucher,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        require(voucherSystemEnabled, "Voucher system not enabled");
        require(address(authorizer) != address(0), "Authorizer not set");
        require(beneficiary != address(0), "Invalid beneficiary");
        require(amount > 0, "Invalid amount");
        require(token != NATIVE_ADDRESS, "Use buyWithNativeVoucher for native currency");
        // Check if any presale is active
        uint8 activeMode = _getActivePresaleMode();
        require(activeMode == 1 || activeMode == 2, "No presale active");
        require(activeMode != 3, "Cannot run both presales simultaneously");
        require(voucher.buyer == msg.sender, "Only buyer can use voucher");
        require(voucher.beneficiary == beneficiary, "Beneficiary mismatch");
        require(voucher.paymentToken == token, "Invalid payment token");
        
        TokenPrice memory tokenPrice = tokenPrices[token];
        require(tokenPrice.isActive, "Token not accepted");
        
        // Transfer and calculate actual received amount
        uint256 actualAmount = _transferAndCalculateActualAmount(token, amount);
        
        // Calculate USD amount based on actual received amount (8 decimals) - user gets tokens for full amount
        uint256 usdAmount = (actualAmount * tokenPrice.priceUSD) / (10 ** tokenPrice.decimals);
        require(usdAmount > 0, "Payment amount too small");
        
        // GRO-19: In-contract replay protection (defense-in-depth)
        bytes32 voucherHash = _computeVoucherHash(voucher);
        require(!usedVoucherHashes[voucherHash], "Voucher already used in this contract");
        
        // Authorize purchase with voucher (external Authorizer)
        require(authorizer.authorize(voucher, signature, token, usdAmount), "Voucher authorization failed");
        
        // Mark voucher as used in this contract
        usedVoucherHashes[voucherHash] = true;
        emit VoucherHashConsumed(voucherHash, voucher.buyer);
        
        // Calculate token amount based on actual received amount
        uint256 tokenAmount = _calculateTokenAmountForVoucher(token, actualAmount, beneficiary, usdAmount);
        require(tokenAmount > 0, "Token amount too small");
        
        // Calculate and transfer 4% fee to dev treasury (using 400/10000 for better precision)
        uint256 devFee = (actualAmount * 400) / 10000;
        IERC20(token).safeTransfer(devTreasury, devFee);
        _processVoucherPurchase(beneficiary, token, actualAmount, tokenAmount, voucher);
    }
    
    // ============ INTERNAL FUNCTIONS ============
    
    /// @notice Transfer tokens and calculate actual received amount (handles fee-on-transfer tokens)
    /// @param token Token address to transfer
    /// @param amount Amount to transfer
    /// @return actualAmount Actual amount received after transfer
    function _transferAndCalculateActualAmount(address token, uint256 amount) internal returns (uint256 actualAmount) {
        // Record balance before transfer to detect fee-on-transfer tokens
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Transfer tokens (SafeERC20 handles USDT compatibility)
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Calculate actual amount received (handles deflationary/fee-on-transfer tokens)
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        actualAmount = balanceAfter - balanceBefore;
        require(actualAmount > 0, "No tokens received");
        
        // GRO-09: Reject deflationary tokens
        require(actualAmount == amount, "Deflationary token not supported");
    }
    
    function _ensurePresaleActive() internal view {
        bool mainPresaleActive = presaleStartTime > 0 &&
            block.timestamp >= presaleStartTime &&
            block.timestamp <= presaleEndTime &&
            !presaleEnded;
            
        bool escrowPresaleActive = escrowPresaleStartTime > 0 &&
            block.timestamp >= escrowPresaleStartTime &&
            block.timestamp <= escrowPresaleEndTime &&
            !escrowPresaleEnded;
        
        require(mainPresaleActive || escrowPresaleActive, "No presale active");
    }
    
    /// @notice Get active presale mode: 0 = none, 1 = main, 2 = escrow, 3 = both (error case)
    function _getActivePresaleMode() internal view returns (uint8) {
        bool mainPresaleActive = presaleStartTime > 0 &&
            block.timestamp >= presaleStartTime &&
            block.timestamp <= presaleEndTime &&
            !presaleEnded;
            
        bool escrowPresaleActive = escrowPresaleStartTime > 0 &&
            block.timestamp >= escrowPresaleStartTime &&
            block.timestamp <= escrowPresaleEndTime &&
            !escrowPresaleEnded;
        
        if (mainPresaleActive && escrowPresaleActive) {
            return 3; // Error case - both active
        } else if (mainPresaleActive) {
            return 1; // Main presale active
        } else if (escrowPresaleActive) {
            return 2; // Escrow presale active
        } else {
            return 0; // No presale active
        }
    }
    
    /// @notice Calculate token amount for voucher purchases (USD amount already calculated in 8 decimals)
    /// @dev USD tracking is now handled in _processVoucherPurchase to avoid double counting
    function _calculateTokenAmountForVoucher(address /* paymentToken */, uint256 /* paymentAmount */, address /* beneficiary */, uint256 usdAmount) internal view returns (uint256) {
        require(usdAmount > 0, "USD amount too small");
        
        // Calculate presale tokens: usdAmount (8 dec) * presaleRate (18 dec) / 1e8 = tokens (18 dec)
        uint256 tokenAmount = (usdAmount * presaleRate) / 1e8;
        require(tokenAmount > 0, "Token amount too small");
        
        return tokenAmount;
    }
    
    function _processPurchase(
        address beneficiary,
        address paymentToken,
        uint256 paymentAmount,
        uint256 tokenAmount
    ) internal {
        _ensurePresaleActive();
        
        // Check if we can mint enough tokens
        require(totalTokensMinted + tokenAmount <= maxTokensToMint, "Not enough tokens left");
        
        // Update tracking
        purchasedAmounts[beneficiary][paymentToken] += paymentAmount;
        totalPurchased[beneficiary] += tokenAmount;
        totalTokensMinted += tokenAmount;
        
        // Track tokens sold per round based on active presale mode
        uint8 activeMode = _getActivePresaleMode();
        if (activeMode == 1) {
            // Main presale
            if (currentRound == 1) {
                round1TokensSold += tokenAmount;
            } else if (currentRound == 2) {
                round2TokensSold += tokenAmount;
            }
        } else if (activeMode == 2) {
            // Escrow presale
            if (escrowCurrentRound == 1) {
                escrowRound1TokensSold += tokenAmount;
            } else if (escrowCurrentRound == 2) {
                escrowRound2TokensSold += tokenAmount;
            }
        }
        
        emit TokenPurchase(msg.sender, beneficiary, paymentToken, paymentAmount, tokenAmount);
        
        // Check auto-end conditions
        _checkAutoEndConditions();
    }
    
    /// @notice Process voucher-based purchase
    function _processVoucherPurchase(
        address beneficiary,
        address paymentToken,
        uint256 paymentAmount,
        uint256 tokenAmount,
        Authorizer.Voucher calldata voucher
    ) internal {
        _ensurePresaleActive();
        
        // Check if we can mint enough tokens
        require(totalTokensMinted + tokenAmount <= maxTokensToMint, "Not enough tokens left");
        
        // Calculate and track USD spent for analytics
        // Note: paymentAmount for native payments is already adjusted for gas buffer
        TokenPrice memory price = tokenPrices[paymentToken];
        uint256 usdAmount = (paymentAmount * price.priceUSD) / (10 ** price.decimals);
        totalUsdPurchased[beneficiary] += usdAmount;
        
        // Update tracking
        purchasedAmounts[beneficiary][paymentToken] += paymentAmount;
        totalPurchased[beneficiary] += tokenAmount;
        totalTokensMinted += tokenAmount;
        
        // Track tokens sold per round based on active presale mode
        uint8 activeMode = _getActivePresaleMode();
        if (activeMode == 1) {
            // Main presale
            if (currentRound == 1) {
                round1TokensSold += tokenAmount;
            } else if (currentRound == 2) {
                round2TokensSold += tokenAmount;
            }
        } else if (activeMode == 2) {
            // Escrow presale
            if (escrowCurrentRound == 1) {
                escrowRound1TokensSold += tokenAmount;
            } else if (escrowCurrentRound == 2) {
                escrowRound2TokensSold += tokenAmount;
            }
        }
        
        // Generate voucher hash for event
        bytes32 voucherHash = keccak256(abi.encode(
            voucher.buyer,
            voucher.beneficiary,
            voucher.paymentToken,
            voucher.usdLimit,
            voucher.nonce,
            voucher.deadline,
            voucher.presale
        ));
        
        emit VoucherPurchase(msg.sender, beneficiary, paymentToken, paymentAmount, tokenAmount, voucherHash);
        emit TokenPurchase(msg.sender, beneficiary, paymentToken, paymentAmount, tokenAmount);
        
        // Check auto-end conditions
        _checkAutoEndConditions();
    }
    
    // Check if presale should auto-end
    function _checkAutoEndConditions() internal {
        uint8 activeMode = _getActivePresaleMode();
        
        // End if all tokens sold
        if (totalTokensMinted >= maxTokensToMint) {
            if (activeMode == 1) {
                // End main presale
                presaleEnded = true;
                presaleEndTime = block.timestamp;
            } else if (activeMode == 2) {
                // End escrow presale
                escrowPresaleEnded = true;
                escrowPresaleEndTime = block.timestamp;
            }
            emit PresaleEndedEarly("All tokens sold", block.timestamp);
            emit PresaleEnded(block.timestamp);
            return;
        }
        
        // Check duration limits based on active presale
        if (activeMode == 1) {
            // Main presale: End if 34 days passed
            if (block.timestamp >= presaleStartTime + MAX_PRESALE_DURATION) {
                presaleEnded = true;
                presaleEndTime = block.timestamp;
                emit PresaleEndedEarly("Maximum duration reached", block.timestamp);
                emit PresaleEnded(block.timestamp);
                return;
            }
        } else if (activeMode == 2) {
            // Escrow presale: End if 34 days passed
            if (block.timestamp >= escrowPresaleStartTime + MAX_PRESALE_DURATION) {
                escrowPresaleEnded = true;
                escrowPresaleEndTime = block.timestamp;
                emit PresaleEndedEarly("Maximum duration reached", block.timestamp);
                emit PresaleEnded(block.timestamp);
                return;
            }
        }
        
        // Note: Auto-advancement to Round 2 disabled to prevent price inconsistencies
        // Use moveToRound2() or moveEscrowToRound2() functions instead to ensure proper price updates
    }
    
    // ============ CLAIM FUNCTIONS ============
    
    function claimTokens() external nonReentrant whenNotPaused {
        require(totalPurchased[msg.sender] > 0, "No tokens to claim");
        require(!hasClaimed[msg.sender], "Already claimed");
        require(presaleEnded || escrowPresaleEnded, "No presale ended yet");
        
        uint256 claimAmount = totalPurchased[msg.sender];
        hasClaimed[msg.sender] = true;
        
        presaleToken.safeTransfer(msg.sender, claimAmount);
        
        emit TokensClaimed(msg.sender, claimAmount);
    }
    
    // ============ ADMIN FUNCTIONS ============
    
    function withdrawNative() external onlyGovernance {
        uint256 balance = address(this).balance;
        require(balance > 0, "No native currency to withdraw");
        payable(treasury).transfer(balance);
    }
    
    function withdrawToken(address token) external onlyGovernance {
        require(token != address(presaleToken), "Cannot withdraw presale tokens directly");

        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No tokens to withdraw");
        IERC20(token).safeTransfer(treasury, balance);
    }
    
    /// @notice Burn unsold presale tokens after presale ends
    /// @dev Only owner can call this to burn remaining tokens in presale contract
    function burnUnsoldTokens() external onlyGovernance nonReentrant {
        require(presaleEnded || escrowPresaleEnded, "Presale must be ended first");
        
        uint256 unsoldAmount = presaleToken.balanceOf(address(this));
        require(unsoldAmount > 0, "No tokens to burn");
        
        // Call burn function on EscrowToken (ERC20Burnable)
        // This will burn tokens from this contract's balance
        (bool success, ) = address(presaleToken).call(
            abi.encodeWithSignature("burn(uint256)", unsoldAmount)
        );
        require(success, "Burn failed");
    }
    
    function pause() external onlyGovernance {
        _pause();
    }
    
    function unpause() external onlyGovernance {
        _unpause();
    }
    
    // ============ VIEW FUNCTIONS ============
    
    function getTokenPrice(address token) external view returns (TokenPrice memory) {
        return tokenPrices[token];
    }
    
    function getUserPurchases(address user) external view returns (
        uint256 nativeAmount,
        uint256 totalTokens,
        bool claimed
    ) {
        nativeAmount = purchasedAmounts[user][NATIVE_ADDRESS];
        totalTokens = totalPurchased[user];
        claimed = hasClaimed[user];
    }
    
    function calculateTokenAmount(address paymentToken, uint256 paymentAmount, address /* beneficiary */) external view returns (uint256) {
        TokenPrice memory price = tokenPrices[paymentToken];
        require(price.isActive, "Token not accepted");
        
        // Convert payment amount to USD value
        uint256 usdValue = (paymentAmount * price.priceUSD) / (10 ** price.decimals * 10 ** USD_DECIMALS);
        require(usdValue > 0, "Payment amount too small");
        
        // View function for external queries - no limits enforced here
        // Per-user and total token supply limits enforced in actual purchase functions
        // Calculate presale tokens
        uint256 tokenAmount = (usdValue * presaleRate);
        require(tokenAmount > 0, "Token amount too small");
        
        return tokenAmount;
    }
    
    function getRemainingTokens() external view returns (uint256) {
        return maxTokensToMint - totalTokensMinted;
    }
    
    // Presale status functions
    function getPresaleStatus() external view returns (
        bool started,
        bool ended,
        uint256 startTime,
        uint256 endTime,
        uint256 currentTime
    ) {
        started = presaleStartTime > 0;
        ended = presaleEnded;
        startTime = presaleStartTime;
        endTime = presaleEndTime;
        currentTime = block.timestamp;
    }
    
    function isPresaleActive() external view returns (bool) {
        bool mainPresaleActive = presaleStartTime > 0 && 
               block.timestamp >= presaleStartTime && 
               block.timestamp <= presaleEndTime && 
               !presaleEnded;
               
        bool escrowPresaleActive = escrowPresaleStartTime > 0 && 
               block.timestamp >= escrowPresaleStartTime && 
               block.timestamp <= escrowPresaleEndTime && 
               !escrowPresaleEnded;
               
        return mainPresaleActive || escrowPresaleActive;
    }
    
    function canClaim() external view returns (bool) {
        // Can claim if either presale has explicitly ended OR if time has expired
        bool mainPresaleTimeExpired = presaleStartTime > 0 && block.timestamp > presaleEndTime;
        bool escrowPresaleTimeExpired = escrowPresaleStartTime > 0 && block.timestamp > escrowPresaleEndTime;
        
        return presaleEnded || escrowPresaleEnded || mainPresaleTimeExpired || escrowPresaleTimeExpired;
    }
    
    // Get escrow presale status
    function getEscrowPresaleStatus() external view returns (
        bool started,
        bool ended,
        uint256 startTime,
        uint256 endTime,
        uint256 currentTime
    ) {
        started = escrowPresaleStartTime > 0;
        ended = escrowPresaleEnded;
        startTime = escrowPresaleStartTime;
        endTime = escrowPresaleEndTime;
        currentTime = block.timestamp;
    }
    
    // Get comprehensive escrow presale status
    function getIEscrowPresaleStatus() external view returns (
        uint256 currentRoundNumber,
        uint256 roundTimeRemaining,
        uint256 totalTimeRemaining,
        uint256 tokensRemainingTotal,
        uint256 round1Sold,
        uint256 round2Sold,
        bool canPurchase,
        string memory statusMessage
    ) {
        currentRoundNumber = escrowCurrentRound;
        round1Sold = escrowRound1TokensSold;
        round2Sold = escrowRound2TokensSold;
        tokensRemainingTotal = maxTokensToMint - totalTokensMinted;
        
        if (escrowPresaleEnded) {
            canPurchase = false;
            statusMessage = "Escrow presale ended";
            roundTimeRemaining = 0;
            totalTimeRemaining = 0;
        } else if (escrowCurrentRound == 0) {
            canPurchase = false;
            statusMessage = "Escrow presale starts Nov 11, 2025";
            roundTimeRemaining = block.timestamp >= PRESALE_LAUNCH_DATE ? 0 : PRESALE_LAUNCH_DATE - block.timestamp;
            totalTimeRemaining = roundTimeRemaining;
        } else if (escrowCurrentRound == 1) {
            canPurchase = true;
            statusMessage = "Escrow Round 1 Active";
            roundTimeRemaining = block.timestamp >= escrowRound1EndTime ? 0 : escrowRound1EndTime - block.timestamp;
            totalTimeRemaining = block.timestamp >= escrowPresaleEndTime ? 0 : escrowPresaleEndTime - block.timestamp;
        } else if (escrowCurrentRound == 2) {
            canPurchase = true;
            statusMessage = "Escrow Round 2 Active";
            roundTimeRemaining = block.timestamp >= escrowPresaleEndTime ? 0 : escrowPresaleEndTime - block.timestamp;
            totalTimeRemaining = roundTimeRemaining;
        }
        
        return (currentRoundNumber, roundTimeRemaining, totalTimeRemaining, tokensRemainingTotal, round1Sold, round2Sold, canPurchase, statusMessage);
    }
    
    // Get round allocation details
    function getRoundAllocation() external view returns (
        uint256 round1Sold,
        uint256 round2Sold,
        uint256 round1Remaining,
        uint256 round2Remaining,
        uint256 totalRemaining
    ) {
        round1Sold = round1TokensSold;
        round2Sold = round2TokensSold;
        totalRemaining = maxTokensToMint - totalTokensMinted;
        
        // For display purposes - no hard limits per round in iEscrow spec
        round1Remaining = totalRemaining;
        round2Remaining = totalRemaining;
        
        return (round1Sold, round2Sold, round1Remaining, round2Remaining, totalRemaining);
    }
    
    // Validate contract setup before launch
    function validateIEscrowSetup() external view returns (
        bool hasCorrectTokens,
        bool startDateConfigured,
        bool limitsConfigured,
        bool tokensDeposited,
        string memory issues
    ) {
        hasCorrectTokens = true; // All 7 tokens configured in constructor
        startDateConfigured = PRESALE_LAUNCH_DATE == 1762819200; // Nov 11, 2025
        limitsConfigured = maxTokensToMint == 5000000000 * 1e18; // 5B tokens
        
        uint256 contractBalance = presaleToken.balanceOf(address(this));
        tokensDeposited = contractBalance >= maxTokensToMint;
        
        if (!tokensDeposited) {
            issues = "Insufficient ESCROW tokens in contract";
        } else if (!startDateConfigured) {
            issues = "Incorrect start date";
        } else if (!limitsConfigured) {
            issues = "Incorrect token limits";
        } else {
            issues = "Setup validated - ready for launch";
        }
        
        return (hasCorrectTokens, startDateConfigured, limitsConfigured, tokensDeposited, issues);
    }
    
    // Anyone can call to trigger auto-end checks
    function checkAutoEndConditions() external {
        uint8 activeMode = _getActivePresaleMode();
        require(activeMode == 1 || activeMode == 2, "No presale active");
        _checkAutoEndConditions();
    }
    
    // Helper functions for USD value calculations - GRO-13 Refactoring
    function _convertToUsd(address paymentToken, uint256 amount) internal view returns (uint256 usdValue) {
        TokenPrice memory price = tokenPrices[paymentToken];
        require(price.isActive, "Token not accepted");
        
        // Convert to USD value in 8 decimal format
        // price.priceUSD is already in 8 decimals (e.g., $4200 = 420000000000)
        usdValue = (amount * price.priceUSD) / (10 ** price.decimals);
    }
    
    function _handleRoundTransition(uint256 fromRound, uint256 toRound) internal {
        require(fromRound < toRound, "Invalid round transition");
        require(!presaleEnded, "Presale already ended");
        
        currentRound = toRound;
        
        // Update round end time if transitioning from round 1
        if (fromRound == 1) {
            round1EndTime = block.timestamp;
        }
        
        emit RoundAdvanced(fromRound, toRound, block.timestamp);
    }
    
    function _getUSDValue(address token, uint256 amount) internal view returns (uint256) {
        return _convertToUsd(token, amount);
    }
    
    function _getUserTotalUSDValue(address user) internal view returns (uint256) {
        return totalUsdPurchased[user];
    }
    
    function getUserTotalUSDValue(address user) external view returns (uint256) {
        return totalUsdPurchased[user];
    }
    
    // Get all supported tokens information
    function getSupportedTokens() external view returns (
        address[] memory tokens,
        string[] memory symbols,
        uint256[] memory prices,
        bool[] memory active
    ) {
        tokens = new address[](7);
        symbols = new string[](7);
        prices = new uint256[](7);
        active = new bool[](7);
        
        tokens[0] = NATIVE_ADDRESS;
        symbols[0] = "ETH";
        prices[0] = tokenPrices[NATIVE_ADDRESS].priceUSD;
        active[0] = tokenPrices[NATIVE_ADDRESS].isActive;
        
        tokens[1] = WETH_ADDRESS;
        symbols[1] = "WETH";
        prices[1] = tokenPrices[WETH_ADDRESS].priceUSD;
        active[1] = tokenPrices[WETH_ADDRESS].isActive;
        
        tokens[2] = WBNB_ADDRESS;
        symbols[2] = "WBNB";
        prices[2] = tokenPrices[WBNB_ADDRESS].priceUSD;
        active[2] = tokenPrices[WBNB_ADDRESS].isActive;
        
        tokens[3] = LINK_ADDRESS;
        symbols[3] = "LINK";
        prices[3] = tokenPrices[LINK_ADDRESS].priceUSD;
        active[3] = tokenPrices[LINK_ADDRESS].isActive;
        
        tokens[4] = WBTC_ADDRESS;
        symbols[4] = "WBTC";
        prices[4] = tokenPrices[WBTC_ADDRESS].priceUSD;
        active[4] = tokenPrices[WBTC_ADDRESS].isActive;
        
        tokens[5] = USDC_ADDRESS;
        symbols[5] = "USDC";
        prices[5] = tokenPrices[USDC_ADDRESS].priceUSD;
        active[5] = tokenPrices[USDC_ADDRESS].isActive;
        
        tokens[6] = USDT_ADDRESS;
        symbols[6] = "USDT";
        prices[6] = tokenPrices[USDT_ADDRESS].priceUSD;
        active[6] = tokenPrices[USDT_ADDRESS].isActive;
    }
    
    // Get user's purchases for all tokens
    function getUserAllPurchases(address user) external view returns (
        uint256[] memory amounts,
        uint256[] memory usdValues
    ) {
        amounts = new uint256[](7);
        usdValues = new uint256[](7);
        
        address[] memory tokens = new address[](7);
        tokens[0] = NATIVE_ADDRESS;
        tokens[1] = WETH_ADDRESS;
        tokens[2] = WBNB_ADDRESS;
        tokens[3] = LINK_ADDRESS;
        tokens[4] = WBTC_ADDRESS;
        tokens[5] = USDC_ADDRESS;
        tokens[6] = USDT_ADDRESS;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            amounts[i] = purchasedAmounts[user][tokens[i]];
            if (amounts[i] > 0) {
                usdValues[i] = _convertToUsd(tokens[i], amounts[i]);
            }
        }
    }
    
    // Apply an owner-configurable buffer so allocations don't depend on tx.gasprice
    function _applyGasBuffer(uint256 amount) internal view returns (uint256) {
        uint256 buffer = gasBuffer;
        if (buffer == 0) {
            return amount;
        }
        require(amount > buffer, "Insufficient payment after gas buffer");
        return amount - buffer;
    }
    
    function setGasBuffer(uint256 _gasBuffer) external onlyGovernance {
        uint256 oldBuffer = gasBuffer;
        gasBuffer = _gasBuffer;
        emit GasBufferUpdated(oldBuffer, _gasBuffer);
    }
    
    /// @notice Compute voucher hash for in-contract replay protection (GRO-19)
    /// @param voucher The voucher to hash
    /// @return Hash of the voucher
    function _computeVoucherHash(Authorizer.Voucher calldata voucher) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            voucher.buyer,
            voucher.beneficiary,
            voucher.paymentToken,
            voucher.usdLimit,
            voucher.nonce,
            voucher.deadline,
            voucher.presale
        ));
    }
    
    /// @notice Check if a voucher hash has been used in this contract (GRO-19)
    /// @param voucherHash Hash of the voucher
    /// @return True if already used
    function isVoucherUsed(bytes32 voucherHash) external view returns (bool) {
        return usedVoucherHashes[voucherHash];
    }
    
    /// @notice Get active presale mode for external consumption
    function getActivePresaleMode() external view returns (uint8) {
        return _getActivePresaleMode();
    }
    
    /// @notice Get comprehensive status of both presale modes
    function getBothPresalesStatus() external view returns (
        bool mainStarted,
        bool mainEnded,
        bool escrowStarted,
        bool escrowEnded,
        uint8 activeMode,
        string memory statusMessage
    ) {
        mainStarted = presaleStartTime > 0;
        mainEnded = presaleEnded;
        escrowStarted = escrowPresaleStartTime > 0;
        escrowEnded = escrowPresaleEnded;
        activeMode = _getActivePresaleMode();
        
        if (activeMode == 0) {
            statusMessage = "No presale active";
        } else if (activeMode == 1) {
            statusMessage = "Main presale active";
        } else if (activeMode == 2) {
            statusMessage = "Escrow presale active";
        } else if (activeMode == 3) {
            statusMessage = "ERROR: Both presales active";
        }
    }
    
    /// @notice Get escrow presale round allocation details
    function getEscrowRoundAllocation() external view returns (
        uint256 round1Sold,
        uint256 round2Sold,
        uint256 round1Remaining,
        uint256 round2Remaining,
        uint256 totalRemaining
    ) {
        round1Sold = escrowRound1TokensSold;
        round2Sold = escrowRound2TokensSold;
        totalRemaining = maxTokensToMint - totalTokensMinted;
        
        // For display purposes - no hard limits per round in iEscrow spec
        round1Remaining = totalRemaining;
        round2Remaining = totalRemaining;
        
        return (round1Sold, round2Sold, round1Remaining, round2Remaining, totalRemaining);
    }
    
    
    // ============ AUTHORIZER MANAGEMENT FUNCTIONS ============
    
    /// @notice Update the Authorizer contract address
    /// @param _authorizer New Authorizer contract address
    function updateAuthorizer(address _authorizer) external onlyGovernance {
        require(_authorizer != address(0), "Invalid authorizer");
        require(_authorizer.code.length > 0, "Authorizer must be contract");
        address oldAuthorizer = address(authorizer);
        authorizer = Authorizer(_authorizer);
        emit AuthorizerUpdated(oldAuthorizer, _authorizer);
    }
    
    /// @notice Toggle voucher system on/off
    /// @param _enabled Whether voucher system is enabled
    function setVoucherSystemEnabled(bool _enabled) external onlyGovernance {
        voucherSystemEnabled = _enabled;
        emit VoucherSystemToggled(_enabled);
    }
    
    /// @notice Get Authorizer contract address and system status
    /// @return authorizerAddress Address of the Authorizer contract
    /// @return enabled Whether voucher system is enabled
    function getAuthorizerInfo() external view returns (address authorizerAddress, bool enabled) {
        authorizerAddress = address(authorizer);
        enabled = voucherSystemEnabled;
    }
    
    /// @notice Validate a voucher without consuming it (view function)
    /// @param voucher The purchase voucher to validate
    /// @param signature EIP-712 signature of the voucher
    /// @param paymentToken Token being used for payment
    /// @param usdAmount USD amount being purchased (8 decimals)
    /// @return valid True if voucher is valid
    /// @return reason Reason for invalidity (empty if valid)
    function validateVoucher(
        Authorizer.Voucher calldata voucher,
        bytes calldata signature,
        address paymentToken,
        uint256 usdAmount
    ) external view returns (bool valid, string memory reason) {
        if (!voucherSystemEnabled) {
            return (false, "Voucher system not enabled");
        }
        if (address(authorizer) == address(0)) {
            return (false, "Authorizer not set");
        }
        return authorizer.validateVoucher(voucher, signature, paymentToken, usdAmount);
    }
    
}