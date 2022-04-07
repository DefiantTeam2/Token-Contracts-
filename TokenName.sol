// SPDX-License-Identifier: MIT

pragma solidity ^0.6.2;

import "./DividendPayingToken.sol";
import "./SafeMath.sol";
import "./IterableMapping.sol";
import "./Ownable.sol";
import "./IPancakeV2Pair.sol";
import "./IPancakeV2Factory.sol";
import "./IPancakeV2Router.sol";

contract TokenName is ERC20, Ownable {
    using SafeMath for uint256;

    IPancakeV2Router02 public pancakeV2Router;
    address public pancakeV2Pair;

    bool private swapping;

    TokenNameDividendTracker public dividendTracker;

    address public constant deadWallet =
        0x000000000000000000000000000000000000dEaD;

    uint256 private constant TOTAL_SUPPLY = 1000000000 * (10**18);
    uint256 public constant SWAP_TOKENS_AT_AMOUNT = 2000 * (10**18);
    uint256 public constant PLATFORM_FEE = 75;
    uint256 public maxTxAmount = TOTAL_SUPPLY.mul(5).div(1000); // 0.5%

    uint256 public ethRewardsFee = 400;
    uint256 public marketingFee = 200;
    uint256 public devFee = 325;
    uint256 public liquidityFee = 0;
    uint256 public burnFee = 0;
    uint256 public launchSellFee = 0;
    uint256 public totalFees = ethRewardsFee.add(PLATFORM_FEE).add(liquidityFee).add(marketingFee).add(devFee).add(burnFee);

    address private _platformAddress = 0x037c98c77B450412cDB11EA2996630618224D018;
    address private _devWalletAddress = 0xCc76a8323a210F520aBab91300c0400252697358;
    address private _marketingWalletAddress = 0xCc76a8323a210F520aBab91300c0400252697358;

    uint256 public launchSellFeeDeadline = 0;
    uint256 public blacklistDeadline = 0;
    bool public tradingReady = false;

    // use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // fallback to generic transfer
    bool public useGenericTransfer = false;
    
    // blacklist
    mapping(address => bool) public isBlacklisted;

    // exclude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;
    
    // exclude from tx limits
    mapping(address => bool) private _isExcludedFromMaxTx;

    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdatePancakeV2Router(
        address indexed newAddress,
        address indexed oldAddress
    );

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event GasForProcessingUpdated(
        uint256 indexed newValue,
        uint256 indexed oldValue
    );

    event GenericTransferChanged(bool useGenericTransfer);

    event LaunchFeeUpdated();

    event PrepForLaunch(uint256 blocktime);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendDividends(uint256 tokensSwapped, uint256 amount);

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor() public ERC20("TokenName", "TOKENTICK") {
        dividendTracker = new TokenNameDividendTracker();

        IPancakeV2Router02 _pancakeV2Router = IPancakeV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );
        // Create a pancake pair for this new token
        address _pancakeV2Pair = IPancakeV2Factory(_pancakeV2Router.factory())
            .createPair(address(this), _pancakeV2Router.WETH());

        pancakeV2Router = _pancakeV2Router;
        pancakeV2Pair = _pancakeV2Pair;

        _setAutomatedMarketMakerPair(_pancakeV2Pair, true);

        // exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(owner());
        dividendTracker.excludeFromDividends(deadWallet);
        dividendTracker.excludeFromDividends(address(_pancakeV2Router));

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(_marketingWalletAddress, true);
        excludeFromFees(address(this), true);
        
        // internal exclude from max tx
        _isExcludedFromMaxTx[owner()] = true;
        _isExcludedFromMaxTx[address(this)] = true;
    }

    function prepForLaunch() public onlyOwner {
        require(
            !tradingReady,
            "TokenName: Contract has already been prepped for trading."
        );

        tradingReady = true; // once set to true, this function can never be called again.
        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), TOTAL_SUPPLY);
        blacklistDeadline = now + 1 hours; // A maximum of 1 hour is given to blacklist snipers/flashbots
        launchSellFeeDeadline = now + 1 days; // sell penalty for the first 24 hours

        emit PrepForLaunch(now);
    }

    receive() external payable {}

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(
            _isExcludedFromFees[account] != excluded,
            "TokenName: Account is already the value of 'excluded'"
        );
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(
        address[] calldata accounts,
        bool excluded
    ) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setMarketingWallet(address payable wallet) external onlyOwner {
        require(wallet != address(0), "TokenName: Marketing wallet cannot be 0!");
        require(
            wallet != deadWallet,
            "TokenName: Marketing wallet cannot be the dead wallet!"
        );
        _marketingWalletAddress = wallet;
    }

    function setLaunchSellFee(uint256 newLaunchSellFee) external onlyOwner {
        require(newLaunchSellFee <= 2500, "TokenName: Maximum launch sell fee is 25%");
        launchSellFee = newLaunchSellFee;
        emit LaunchFeeUpdated();
    }

    function setFees(uint256 ethRewards, uint256 liquidity, uint256 marketing, uint256 dev, uint256 burn) external onlyOwner {
        require(ethRewards <= 1000, "TokenName: Maximum ETH reward fee is 10%");
        require(liquidity <= 500, "TokenName: Maximum liquidity fee is 5%");
        require(marketing <= 500, "TokenName: Maximum marketing fee is 5%");
        require(dev <= 500, "TokenName: Maximum dev fee is 5%");
        require(burn <= 500, "TokenName: Maximum burn fee is 5%");
        ethRewardsFee = ethRewards;
        liquidityFee = liquidity;
        marketingFee = marketing;
        devFee = dev;
        burnFee = burn;
        totalFees = ethRewardsFee.add(PLATFORM_FEE).add(liquidityFee).add(marketingFee).add(devFee).add(burnFee);
    }

    function setAutomatedMarketMakerPair(address pair, bool value)
        public
        onlyOwner
    {
        require(
            pair != pancakeV2Pair,
            "TokenName: The Pancake pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    function blacklistAddress(address account, bool value) public onlyOwner {
        if (value) {
            require(
                now < blacklistDeadline,
                "TokenName: The ability to blacklist accounts has been disabled."
            );
        }
        isBlacklisted[account] = value;
    }

    // for 0.5% input 5, for 1% input 10
    function setMaxTxPercent(uint256 newMaxTx) public onlyOwner {
        require(newMaxTx >= 5, "TokenName: Max TX should be above 0.5%");
        maxTxAmount = TOTAL_SUPPLY.mul(newMaxTx).div(1000);
    }

    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "TokenName: Automated market maker pair is already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function updateGasForProcessing(uint256 newValue) public onlyOwner {
        require(
            newValue >= 200000 && newValue <= 500000,
            "TokenName: gasForProcessing must be between 200,000 and 500,000"
        );
        require(
            newValue != gasForProcessing,
            "TokenName: Cannot update gasForProcessing to same value"
        );
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }

    function getClaimWait() external view returns (uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account)
        public
        view
        returns (uint256)
    {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account)
        external
        view
        returns (uint256)
    {
        return dividendTracker.balanceOf(account);
    }

    function excludeFromDividends(address account) external onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    function getAccountDividendsInfo(address account)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccountAtIndex(index);
    }

    function processDividendTracker(uint256 gas) external {
        (
            uint256 iterations,
            uint256 claims,
            uint256 lastProcessedIndex
        ) = dividendTracker.process(gas);
        emit ProcessedDividendTracker(
            iterations,
            claims,
            lastProcessedIndex,
            false,
            gas,
            tx.origin
        );
    }

    function claim() external {
        dividendTracker.processAccount(msg.sender, false);
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns (uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(
            !isBlacklisted[from] && !isBlacklisted[to],
            "Blacklisted address"
        );

        // fallback implementation
        if (useGenericTransfer) {
            super._transfer(from, to, amount);
            return;
        }

        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }
        
        if (
            !_isExcludedFromMaxTx[from] &&
            !_isExcludedFromMaxTx[to] // by default false
        ) {
            require(
                amount <= maxTxAmount,
                "TokenName: Transfer amount exceeds the maxTxAmount."
            );
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= SWAP_TOKENS_AT_AMOUNT;

        uint256 totalCalculatedFee = totalFees;
        uint256 totalMarketingFee = marketingFee;
        if (launchSellFeeDeadline >= now && to == pancakeV2Pair) {
            totalCalculatedFee = totalCalculatedFee.add(launchSellFee);
            totalMarketingFee = totalMarketingFee.add(launchSellFee);
        }
        
        if (
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != owner() &&
            to != owner() &&
            totalCalculatedFee != 0
        ) {
            swapping = true;

            uint256 platformTokens = contractTokenBalance.mul(PLATFORM_FEE).div(totalCalculatedFee);
            if (platformTokens > 0) {
                swapAndSendToPlatform(platformTokens);
            }

            uint256 burnTokens = contractTokenBalance.mul(burnFee).div(totalCalculatedFee);
            if (burnTokens > 0) {
                sendTokensToBurnWallet(burnTokens);
            }

            uint256 devTokens = contractTokenBalance
                .mul(devFee)
                .div(totalCalculatedFee);
            if (devTokens > 0) {
                swapAndSendToDev(devTokens);
            }

            uint256 marketingTokens = contractTokenBalance
                .mul(totalMarketingFee)
                .div(totalCalculatedFee);
            if (marketingTokens > 0) {
                swapAndSendToFee(marketingTokens);
            }

            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(totalCalculatedFee);
            if (swapTokens > 0) {
                swapAndLiquify(swapTokens);
            }

            uint256 sellTokens = balanceOf(address(this));
            if (sellTokens > 0) {
                swapAndSendDividends(sellTokens);
            }

            swapping = false;
        }
        
        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (_isExcludedFromFees[from] || _isExcludedFromFees[to] || totalCalculatedFee == 0) {
            takeFee = false;
        }

        if (takeFee) {
            uint256 fees = amount.mul(totalCalculatedFee).div(10000);
            amount = amount.sub(fees);
            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (!swapping) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (
                uint256 iterations,
                uint256 claims,
                uint256 lastProcessedIndex
            ) {
                emit ProcessedDividendTracker(
                    iterations,
                    claims,
                    lastProcessedIndex,
                    true,
                    gas,
                    tx.origin
                );
            } catch {}
        }
    }

    function setUseGenericTransfer(bool genericTransfer) external onlyOwner {
        useGenericTransfer = genericTransfer;
        emit GenericTransferChanged(genericTransfer);
    }

    function sendTokensToBurnWallet(uint256 tokens) private {
        super._transfer(address(this), deadWallet, tokens);
    }

    function swapAndSendToPlatform(uint256 tokens) private {
        uint256 initialEthBalance = address(this).balance;

        swapTokensForEth(tokens);
        uint256 newBalance = address(this).balance.sub(initialEthBalance);
        payable(_platformAddress).transfer(newBalance);
    }

    function swapAndSendToDev(uint256 tokens) private {
        uint256 initialEthBalance = address(this).balance;

        swapTokensForEth(tokens);
        uint256 newBalance = address(this).balance.sub(initialEthBalance);
        payable(_devWalletAddress).transfer(newBalance);
    }

    function swapAndSendToFee(uint256 tokens) private {
        uint256 initialEthBalance = address(this).balance;

        swapTokensForEth(tokens);
        uint256 newBalance = address(this).balance.sub(initialEthBalance);
        payable(_marketingWalletAddress).transfer(newBalance);
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);
        uint256 dividends = address(this).balance;
        (bool success, ) = address(dividendTracker).call{value: dividends}("");

        if (success) {
            dividendTracker.distributeDividends(dividends);
            emit SendDividends(tokens, dividends);
        }
    }

    function swapAndLiquify(uint256 tokens) private {
        // split the contract balance into halves
        uint256 half = tokens.div(2);
        uint256 otherHalf = tokens.sub(half);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        uint256 initialBalance = address(this).balance;

        // swap tokens for ETH
        swapTokensForEth(half);

        // how much ETH did we just swap into?
        uint256 newBalance = address(this).balance.sub(initialBalance);

        // add liquidity to pancake
        if (newBalance > 0) {
            addLiquidity(otherHalf, newBalance);

            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the Dex pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeV2Router.WETH();

        _approve(address(this), address(pancakeV2Router), tokenAmount);

        // make the swap
        pancakeV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pancakeV2Router), tokenAmount);

        // add the liquidity
        pancakeV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );

    }
   
    function manualSwap() external onlyOwner() {
        uint256 contractBalance = balanceOf(address(this));
        swapTokensForEth(contractBalance);
    }

    function manualSend() external onlyOwner() {
        uint256 contractEthBalance = address(this).balance;
        payable(_marketingWalletAddress).transfer(contractEthBalance);
    }
}

contract TokenNameDividendTracker is Ownable, DividendPayingToken {
    using SafeMath for uint256;
    using SafeMathInt for int256;
    using IterableMapping for IterableMapping.Map;

    IterableMapping.Map private tokenHoldersMap;
    uint256 public lastProcessedIndex;

    mapping(address => bool) public excludedFromDividends;

    mapping(address => uint256) public lastClaimTimes;

    uint256 public claimWait;
    uint256 public immutable minimumTokenBalanceForDividends;

    event ExcludeFromDividends(address indexed account);
    event ClaimWaitUpdated(uint256 indexed newValue, uint256 indexed oldValue);

    event Claim(
        address indexed account,
        uint256 amount,
        bool indexed automatic
    );

    constructor() public DividendPayingToken("TokenNameDvt", "TokenNameDvt") {
        claimWait = 3600;
        minimumTokenBalanceForDividends = 100000 * (10**18); // must hold 100000+ tokens
    }

    function _transfer(
        address,
        address,
        uint256
    ) internal override {
        require(false, "TokenName_Dividend_Tracker: No transfers allowed");
    }

    function withdrawDividend() public override {
        require(
            false,
            "TokenName_Dividend_Tracker: withdrawDividend disabled. Use the 'claim' function on the main TokenName contract."
        );
    }

    function excludeFromDividends(address account) external onlyOwner {
        require(!excludedFromDividends[account]);
        excludedFromDividends[account] = true;

        _setBalance(account, 0);
        tokenHoldersMap.remove(account);

        emit ExcludeFromDividends(account);
    }

    function updateClaimWait(uint256 newClaimWait) external onlyOwner {
        require(
            newClaimWait >= 1800 && newClaimWait <= 86400,
            "TokenName_Dividend_Tracker: claimWait must be updated to between 30 minutes and 24 hours"
        );
        require(
            newClaimWait != claimWait,
            "TokenName_Dividend_Tracker: Cannot update claimWait to same value"
        );
        emit ClaimWaitUpdated(newClaimWait, claimWait);
        claimWait = newClaimWait;
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return lastProcessedIndex;
    }

    function getNumberOfTokenHolders() external view returns (uint256) {
        return tokenHoldersMap.keys.length;
    }

    function getAccount(address _account)
        public
        view
        returns (
            address account,
            int256 index,
            int256 iterationsUntilProcessed,
            uint256 withdrawableDividends,
            uint256 totalDividends,
            uint256 lastClaimTime,
            uint256 nextClaimTime,
            uint256 secondsUntilAutoClaimAvailable
        )
    {
        account = _account;

        index = tokenHoldersMap.getIndexOfKey(account);

        iterationsUntilProcessed = -1;

        if (index >= 0) {
            if (uint256(index) > lastProcessedIndex) {
                iterationsUntilProcessed = index.sub(
                    int256(lastProcessedIndex)
                );
            } else {
                uint256 processesUntilStartOfArray = tokenHoldersMap
                    .keys
                    .length > lastProcessedIndex
                    ? tokenHoldersMap.keys.length.sub(lastProcessedIndex)
                    : 0;

                iterationsUntilProcessed = index.add(
                    int256(processesUntilStartOfArray)
                );
            }
        }

        withdrawableDividends = withdrawableDividendOf(account);
        totalDividends = accumulativeDividendOf(account);

        lastClaimTime = lastClaimTimes[account];

        nextClaimTime = lastClaimTime > 0 ? lastClaimTime.add(claimWait) : 0;

        secondsUntilAutoClaimAvailable = nextClaimTime > block.timestamp
            ? nextClaimTime.sub(block.timestamp)
            : 0;
    }

    function getAccountAtIndex(uint256 index)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        if (index >= tokenHoldersMap.size()) {
            return (
                0x0000000000000000000000000000000000000000,
                -1,
                -1,
                0,
                0,
                0,
                0,
                0
            );
        }

        address account = tokenHoldersMap.getKeyAtIndex(index);

        return getAccount(account);
    }

    function canAutoClaim(uint256 lastClaimTime) private view returns (bool) {
        if (lastClaimTime > block.timestamp) {
            return false;
        }

        return block.timestamp.sub(lastClaimTime) >= claimWait;
    }

    function setBalance(address payable account, uint256 newBalance)
        external
        onlyOwner
    {
        if (excludedFromDividends[account]) {
            return;
        }

        if (newBalance >= minimumTokenBalanceForDividends) {
            _setBalance(account, newBalance);
            tokenHoldersMap.set(account, newBalance);
        } else {
            _setBalance(account, 0);
            tokenHoldersMap.remove(account);
        }

        processAccount(account, true);
    }

    function process(uint256 gas)
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        uint256 numberOfTokenHolders = tokenHoldersMap.keys.length;

        if (numberOfTokenHolders == 0) {
            return (0, 0, lastProcessedIndex);
        }

        uint256 _lastProcessedIndex = lastProcessedIndex;

        uint256 gasUsed = 0;

        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        uint256 claims = 0;

        while (gasUsed < gas && iterations < numberOfTokenHolders) {
            _lastProcessedIndex++;

            if (_lastProcessedIndex >= tokenHoldersMap.keys.length) {
                _lastProcessedIndex = 0;
            }

            address account = tokenHoldersMap.keys[_lastProcessedIndex];

            if (canAutoClaim(lastClaimTimes[account])) {
                if (processAccount(payable(account), true)) {
                    claims++;
                }
            }

            iterations++;

            uint256 newGasLeft = gasleft();

            if (gasLeft > newGasLeft) {
                gasUsed = gasUsed.add(gasLeft.sub(newGasLeft));
            }

            gasLeft = newGasLeft;
        }

        lastProcessedIndex = _lastProcessedIndex;

        return (iterations, claims, lastProcessedIndex);
    }

    function processAccount(address payable account, bool automatic)
        public
        onlyOwner
        returns (bool)
    {
        uint256 amount = _withdrawDividendOfUser(account);

        if (amount > 0) {
            lastClaimTimes[account] = block.timestamp;
            emit Claim(account, amount, automatic);
            return true;
        }

        return false;
    }
}
