// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./libs/BEP20.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";

// YieldBitcoinToken

contract YieldBitcoinToken is BEP20 {

    uint256 public constant MAXIMUM_SUPPLY = 21000000 * 10 ** 18;

    // Transfer tax rate in basis points. (default 5%)
    uint16 public transferTaxRate = 1000;
    // Burn rate % of transfer tax. (default 20% x 5% = 1% of total amount).
    uint16 public burnRate = 20;

    // Burn address
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // Max transfer amount rate in basis points. (default is 0.5% of total supply)
    uint16 public maxTransferAmountRate = 50;
    // Addresses that excluded from antiWhale
    mapping(address => bool) private _excludedFromAntiWhale;

    // Addresses that excluded from taxFee
    mapping(address => bool) private _excludedFromTaxFee;

    // Automatic swap and liquify enabled
    bool public swapAndLiquifyEnabled = true;
    // Min amount to liquify. (default 500 yBTCs)
    uint256 public minAmountToLiquify = 1050 * 10 ** 18;
    // The swap router, modifiable. Will be changed to PancakeSwap's router when our own AMM release
    IUniswapV2Router02 public pancakeSwapRouter;
    // The trading pair
    address public pancakeSwapPair;
    // In swap and liquify
    bool private _inSwapAndLiquify;

    // The operator can only update the transfer tax rate
    address private _operator;

    // Events
    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event TransferTaxRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event BurnRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event MaxTransferAmountRateUpdated(address indexed operator, uint256 previousRate, uint256 newRate);
    event SwapAndLiquifyEnabledUpdated(address indexed operator, bool enabled);
    event MinAmountToLiquifyUpdated(address indexed operator, uint256 previousAmount, uint256 newAmount);
    event PancakeSwapRouterUpdated(address indexed operator, address indexed router, address indexed pair);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    modifier onlyOperator() {
        require(_operator == msg.sender, "operator: caller is not the operator");
        _;
    }

    modifier antiWhale(address sender, address recipient, uint256 amount) {
        if (maxTransferAmount() > 0) {
            if (
                _excludedFromAntiWhale[sender] == false
                && _excludedFromAntiWhale[recipient] == false
            ) {
                require(amount <= maxTransferAmount(), "yBTC::antiWhale: Transfer amount exceeds the maxTransferAmount");
            }
        }
        _;
    }

    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }

    modifier transferTaxFree {
        uint16 _transferTaxRate = transferTaxRate;
        transferTaxRate = 0;
        _;
        transferTaxRate = _transferTaxRate;
    }

    modifier transferTaxFeeCheck(address sender, address recipient) {
        if(!_inSwapAndLiquify == true && transferTaxRate > 0 && (_excludedFromTaxFee[sender] == true || _excludedFromTaxFee[recipient] == true)){
            uint16 _transferTaxRate = transferTaxRate;
            transferTaxRate = 0;
            _;
            transferTaxRate = _transferTaxRate;
        }else {
            _;
        }
    }

    /**
     * @notice Constructs the YieldBitcoinToken contract.
     */
    constructor() public BEP20("Yield Bitcoin Token", "yBTC") {
        _operator = _msgSender();
        emit OperatorTransferred(address(0), _operator);

        _excludedFromAntiWhale[msg.sender] = true;
        _excludedFromAntiWhale[address(0)] = true;
        _excludedFromAntiWhale[address(this)] = true;
        _excludedFromAntiWhale[BURN_ADDRESS] = true;

        _excludedFromTaxFee[msg.sender] = true;
        _excludedFromTaxFee[BURN_ADDRESS] = true;
        _excludedFromTaxFee[address(this)] = true;

    }

    /// @notice Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) public onlyOwner {
        if(totalSupply().add(_amount) <= MAXIMUM_SUPPLY){
            _mint(_to, _amount);
        }
    }

    /// @dev overrides transfer function to meet tokenomics of yBTC
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override antiWhale(sender, recipient, amount) transferTaxFeeCheck(sender, recipient) {
        // swap and liquify
        if (
            swapAndLiquifyEnabled == true
            && _inSwapAndLiquify == false
            && address(pancakeSwapRouter) != address(0)
            && pancakeSwapPair != address(0)
            && sender != pancakeSwapPair
            && recipient != pancakeSwapPair
            && sender != owner()
        ) {
            swapAndLiquify();
        }

        if (recipient == BURN_ADDRESS || transferTaxRate == 0) {
            super._transfer(sender, recipient, amount);
        } else {
            // default tax is 5% of every transfer
            uint256 taxAmount = amount.mul(transferTaxRate).div(10000);
            uint256 burnAmount = taxAmount.mul(burnRate).div(100);
            uint256 liquidityAmount = taxAmount.sub(burnAmount);
            require(taxAmount == burnAmount + liquidityAmount, "yBTC::transfer: Burn value invalid");

            // default 95% of transfer sent to recipient
            uint256 sendAmount = amount.sub(taxAmount);
            require(amount == sendAmount + taxAmount, "yBTC::transfer: Tax value invalid");

            super._transfer(sender, BURN_ADDRESS, burnAmount);
            super._transfer(sender, address(this), liquidityAmount);
            super._transfer(sender, recipient, sendAmount);
            amount = sendAmount;
        }
    }

    /// @dev Swap and liquify
    function swapAndLiquify() private lockTheSwap transferTaxFree {
        uint256 liquifyAmount = balanceOf(address(this));

        if (liquifyAmount >= minAmountToLiquify) {

            liquifyAmount = minAmountToLiquify;

            uint256 maxTransferAmount = maxTransferAmount();

            if(liquifyAmount > maxTransferAmount)
                liquifyAmount = maxTransferAmount;

            // only min amount to liquify

            // capture the contract's current ETH balance.
            // this is so that we can capture exactly the amount of ETH that the
            // swap creates, and not make the liquidity event include any ETH that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;


            
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = pancakeSwapRouter.WETH();

            uint256[] memory testAmount = pancakeSwapRouter.getAmountsOut(liquifyAmount, path);

            if(initialBalance  >= testAmount[1]){

                addLiquidity(liquifyAmount, testAmount[1]);
                emit SwapAndLiquify(liquifyAmount, testAmount[1], 0);

            }else {
                // split the liquify amount into halves
                uint256 half = liquifyAmount.div(2);
                uint256 otherHalf = liquifyAmount.sub(half);


                // swap tokens for ETH
                swapTokensForEth(half);

                // how much ETH did we just swap into?
                uint256 newBalance = address(this).balance.sub(initialBalance);

                // add liquidity
                addLiquidity(otherHalf, newBalance);

                emit SwapAndLiquify(half, newBalance, otherHalf);
            }
        }
    }

    /// @dev Swap tokens for eth
    function swapTokensForEth(uint256 tokenAmount) private {
        // generate the pancakeSwap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = pancakeSwapRouter.WETH();

        _approve(address(this), address(pancakeSwapRouter), tokenAmount);

        // make the swap
        pancakeSwapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }

    /// @dev Add liquidity
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(pancakeSwapRouter), tokenAmount);

        // add the liquidity
        pancakeSwapRouter.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            operator(),
            block.timestamp
        );
    }

    /**
     * @dev Returns the max transfer amount.
     */
    function maxTransferAmount() public view returns (uint256) {
        return totalSupply().mul(maxTransferAmountRate).div(10000);
    }

    // To receive BNB from pancakeSwapRouter when swapping
    receive() external payable {}

    /**
     * @dev Update the transfer tax rate.
     * Can only be called by the current operator.
     */
    function updateTransferTaxRate(uint16 _transferTaxRate) public onlyOperator {
        require(_transferTaxRate <= 10000, "yBTC::updateTransferTaxRate: Transfer tax rate must not exceed the maximum rate.");
        emit TransferTaxRateUpdated(msg.sender, transferTaxRate, _transferTaxRate);
        transferTaxRate = _transferTaxRate;
    }

    /**
     * @dev Update the burn rate.
     * Can only be called by the current operator.
     */
    function updateBurnRate(uint16 _burnRate) public onlyOperator {
        require(_burnRate <= 100, "yBTC::updateBurnRate: Burn rate must not exceed the maximum rate.");
        emit BurnRateUpdated(msg.sender, burnRate, _burnRate);
        burnRate = _burnRate;
    }

    /**
     * @dev Update the max transfer amount rate.
     * Can only be called by the current operator.
     */
    function updateMaxTransferAmountRate(uint16 _maxTransferAmountRate) public onlyOperator {
        require(_maxTransferAmountRate <= 10000, "yBTC::updateMaxTransferAmountRate: Max transfer amount rate must not exceed the maximum rate.");
        emit MaxTransferAmountRateUpdated(msg.sender, maxTransferAmountRate, _maxTransferAmountRate);
        maxTransferAmountRate = _maxTransferAmountRate;
    }

    /**
     * @dev Update the min amount to liquify.
     * Can only be called by the current operator.
     */
    function updateMinAmountToLiquify(uint256 _minAmount) public onlyOperator {
        emit MinAmountToLiquifyUpdated(msg.sender, minAmountToLiquify, _minAmount);
        minAmountToLiquify = _minAmount;
    }

    /**
     * @dev Returns the address is excluded from antiWhale or not.
     */
    function isExcludedFromAntiWhale(address _account) public view returns (bool) {
        return _excludedFromAntiWhale[_account];
    }

    /**
     * @dev Exclude or include an address from antiWhale.
     * Can only be called by the current operator.
     */
    function setExcludedFromAntiWhale(address _account, bool _excluded) public onlyOperator {
        _excludedFromAntiWhale[_account] = _excluded;
    }

    /**
     * @dev Returns the address is excluded from antiWhale or not.
     */
    function isExcludedFromTaxFee(address _account) public view returns (bool) {
        return _excludedFromTaxFee[_account];
    }

    /**
     * @dev Exclude or include an address from TaxFee.
     * Can only be called by the current operator.
     */
    function setExcludedFromTaxFee(address _account, bool _excluded) public onlyOperator {
        _excludedFromTaxFee[_account] = _excluded;
    }


    /**
     * @dev Update the swapAndLiquifyEnabled.
     * Can only be called by the current operator.
     */
    function updateSwapAndLiquifyEnabled(bool _enabled) public onlyOperator {
        emit SwapAndLiquifyEnabledUpdated(msg.sender, _enabled);
        swapAndLiquifyEnabled = _enabled;
    }

    /**
     * @dev Update the swap router.
     * Can only be called by the current operator.
     */
    function updatePancakeSwapRouter(address _router) public onlyOperator {
        pancakeSwapRouter = IUniswapV2Router02(_router);
        pancakeSwapPair = IUniswapV2Factory(pancakeSwapRouter.factory()).getPair(address(this), pancakeSwapRouter.WETH());
        require(pancakeSwapPair != address(0), "yBTC::updatePancakeSwapRouter: Invalid pair address.");
        emit PancakeSwapRouterUpdated(msg.sender, address(pancakeSwapRouter), pancakeSwapPair);
    }

    /**
     * @dev Returns the address of the current operator.
     */
    function operator() public view returns (address) {
        return _operator;
    }

    /**
     * @dev Transfers operator of the contract to a new account (`newOperator`).
     * Can only be called by the current operator.
     */
    function transferOperator(address newOperator) public onlyOperator {
        require(newOperator != address(0), "yBTC::transferOperator: new operator is the zero address");
        emit OperatorTransferred(_operator, newOperator);
        _operator = newOperator;
    }

}