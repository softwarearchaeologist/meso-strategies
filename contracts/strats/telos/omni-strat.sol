// SPDX-License-Identifier: NONE
pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../FeeManager.sol";
import "../StratManager.sol";
import "../../interfaces/IUNIV2Pair.sol";
import "../../interfaces/IUniswapRouterETH.sol";
import "./omni-Masterchef.sol";

contract BaseMesoStrategyLP is StratManager, FeeManager {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // Tokens used
    address public input; // Token used to stake in the vault
    address public output; // Token rewarded by the delegate Masterchef
    address public constant usdc = 0x818ec0A7Fe18Ff94269904fCED6AE3DaE6d6dC0b; // USDC;
    address public constant Tlos = 0xD102cE6A4dB07D247fcc28F366A623Df0938CA9E; // Tlos;

    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public constant masterchef =
        0x79f5A8BD0d6a00A41EA62cdA426CEf0115117a61; // Omni Masterchef
    uint256 public poolId;

    // Routes
    address[] public outputToUsdcRoute;
    address[] public outputToLp0Route;
    address[] public outputToLp1Route;
    address[] public lpToken0DustToUsdcRoute;
    address[] public lpToken1DustToUsdcRoute;

    bool public panicState = false;
    bool public harvestOnDeposit;
    uint256 public lastHarvest;

    /**
     * @dev Event that is fired each time someone harvests the strat.
     */
    event StratHarvest(address indexed harvester);
    event StratHarvestFromMangager(address indexed _StratHarvestFromMangager);
    event StratHarvestOnDeposit(bool indexed _harvestOnDeposit);
    event StratPanic(address indexed _panic);

    constructor(
        address _input,
        address _output,
        uint256 _pid
    ) public {
        require(
            _input != _output,
            "Meso Strat Error (Constructor): Input token cannot be the same as output token"
        );

        input = _input;
        output = _output;
        poolId = _pid;

        unirouter = 0xF9678db1CE83f6f51E5df348E2Cc842Ca51EfEc1; //Omni
        lpToken0 = IUniswapV2Pair(input).token0();
        lpToken1 = IUniswapV2Pair(input).token1();

        require(
            _input != lpToken0 && _input != lpToken1,
            "Meso Strat Error (Constructor): Input token cannot be the same as any of the lpTokens"
        );

        outputToUsdcRoute = new address[](2);
        outputToUsdcRoute[0] = output;
        outputToUsdcRoute[1] = usdc;

        outputToLp0Route = new address[](2);
        outputToLp0Route[0] = output;
        outputToLp0Route[1] = lpToken0;

        outputToLp1Route = new address[](2);
        outputToLp1Route[0] = output;
        outputToLp1Route[1] = lpToken1;

        lpToken0DustToUsdcRoute = new address[](3);
        lpToken0DustToUsdcRoute[0] = lpToken0;
        lpToken0DustToUsdcRoute[1] = Tlos;
        lpToken0DustToUsdcRoute[2] = usdc;

        lpToken1DustToUsdcRoute = new address[](3);
        lpToken1DustToUsdcRoute[0] = lpToken1;
        lpToken1DustToUsdcRoute[1] = Tlos;
        lpToken1DustToUsdcRoute[2] = usdc;

        _giveAllowances();
    }

    function inputToken() external view returns (IERC20) {
        return IERC20(input);
    }

    // function getDepositFee() external view returns (uint16) {
    //     (, , , , uint16 depositFee, ) = IMasterChef(masterchef).poolInfo(poolId);
    //     return depositFee;
    // }

    // Puts the funds to work
    function deposit(uint256 _amount) public whenNotPaused {
        require(
            msg.sender == vault ||
                msg.sender == address(this) ||
                msg.sender == harvester,
            "Meso Strat Error (Deposit): Unauthorized access. Only the vault, harvester, or this contract can access this."
        );

        uint256 wantBal = IERC20(input).balanceOf(address(this));

        if (_amount > 0 && wantBal > 0) {
            IMasterChef(masterchef).deposit(poolId, _amount);
        }
    }

    function withdraw(uint256 _amount) external {
        require(
            msg.sender == vault,
            "Meso Strat Error (Withdraw): Unauthorized Access. Only the vault can access this."
        );

        uint256 wantBal = IERC20(input).balanceOf(address(this));

        if (wantBal < _amount) {
            IMasterChef(masterchef).withdraw(poolId, _amount.sub(wantBal));
            wantBal = IERC20(input).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        IERC20(input).safeTransfer(vault, wantBal);
    }

    function beforeDeposit() external override {
        if (harvestOnDeposit) {
            require(
                msg.sender == vault ||
                    msg.sender == address(this) ||
                    msg.sender == harvester,
                "Meso Strat Error (Before Deposit): Unauthorized access. Only the vault, harvester, or this contract can access this."
            );
            _harvest();
        }
    }

    function harvest() external virtual whenNotPaused onlyHarvester {
        _harvest();
    }

    function managerHarvest() external onlyManager {
        _harvest();
        emit StratHarvestFromMangager(msg.sender);
    }

    // compounds earnings and charges performance fee
    function _harvest() internal whenNotPaused {
        IMasterChef(masterchef).deposit(poolId, 0);
        uint256 outputBal = IERC20(output).balanceOf(address(this));
        if (outputBal > 0) {
            chargeFees();
            addLiquidity();

            uint256 wantBal = IERC20(input).balanceOf(address(this));
            deposit(wantBal);
        }

        lastHarvest = now;
        emit StratHarvest(msg.sender);
    }

    // performance fees
    function chargeFees() internal {
        if (STRATEGIST_FEE > 0) {
            uint256 toUsdc = IERC20(output)
                .balanceOf(address(this))
                .mul(STRATEGIST_FEE)
                .div(10000);

            IUniswapRouterETH(unirouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    toUsdc,
                    0,
                    outputToUsdcRoute,
                    strategist,
                    now
                );
        }
    }

    // Adds liquidity to AMM and gets more LP tokens.
    function addLiquidity() internal {
        uint256 outputHalf = IERC20(output).balanceOf(address(this)).div(2);

        if (lpToken0 != output) {
            IUniswapRouterETH(unirouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    outputHalf,
                    0,
                    outputToLp0Route,
                    address(this),
                    now
                );
        }

        if (lpToken1 != output) {
            IUniswapRouterETH(unirouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    outputHalf,
                    0,
                    outputToLp1Route,
                    address(this),
                    now
                );
        }

        uint256 lp0Bal = IERC20(lpToken0).balanceOf(address(this));
        uint256 lp1Bal = IERC20(lpToken1).balanceOf(address(this));
        IUniswapRouterETH(unirouter).addLiquidity(
            lpToken0,
            lpToken1,
            lp0Bal,
            lp1Bal,
            1,
            1,
            address(this),
            now
        );
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(input).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        (uint256 _amount, ) = IMasterChef(masterchef).userInfo(
            poolId,
            address(this)
        );
        return _amount;
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        emit StratHarvestOnDeposit(_harvestOnDeposit);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() external onlyManager {
        pause();
        IMasterChef(masterchef).emergencyWithdraw(poolId);

        panicState = true;

        emit StratPanic(msg.sender);
    }

    function panicStatus() external view returns (bool) {
        return panicState;
    }

    function pause() public onlyManager {
        _pause();
        _removeAllowances();
    }

    function unpause() external onlyManager {
        require(
            panicState == false,
            "Meso Strat Error (Unpause): Strategy is in panic mode."
        );
        _unpause();
        _giveAllowances();

        uint256 wantBal = IERC20(input).balanceOf(address(this));
        deposit(wantBal);
    }

    function _giveAllowances() internal {
        IERC20(input).safeApprove(masterchef, uint256(-1));
        IERC20(output).safeApprove(unirouter, uint256(-1));

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, uint256(-1));
        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, uint256(-1));
    }

    function _removeAllowances() internal {
        IERC20(input).safeApprove(masterchef, 0);
        IERC20(output).safeApprove(unirouter, 0);

        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
    }

    function outputToUsdc() external view returns (address[] memory) {
        return outputToUsdcRoute;
    }

    function outputToLp0() external view returns (address[] memory) {
        return outputToLp0Route;
    }

    function outputToLp1() external view returns (address[] memory) {
        return outputToLp1Route;
    }

    function convertDust() external onlyManager {
        uint256 lpToken0Dust = IERC20(lpToken0).balanceOf(address(this));
        uint256 lpToken1Dust = IERC20(lpToken1).balanceOf(address(this));

        if (lpToken0Dust > 0) {
            IUniswapRouterETH(unirouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    lpToken0Dust,
                    0,
                    lpToken0DustToUsdcRoute,
                    strategist,
                    now
                );
        }

        if (lpToken1Dust > 0) {
            IUniswapRouterETH(unirouter)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    lpToken1Dust,
                    0,
                    lpToken1DustToUsdcRoute,
                    strategist,
                    now
                );
        }
    }
}
