// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Minimal {
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

/// @title MockERC20
/// @notice Multi-decimal bounded-supply ERC-20 token (6-decimal USDC/USDG, 8-decimal WBTC, 18-decimal WETH/ARB) (`v0.7.0`).
contract MockERC20 is IERC20Minimal {
    uint256 public constant MAX_MINT_SUPPLY_WAD = 1_000_000_000_000 * 1e18;

    string public name;
    string public symbol;
    uint8 public immutable override decimals;
    uint256 public immutable maxRawSupply;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        require(decimals_ <= 18, "ERC20: decimals > 18");
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        maxRawSupply = MAX_MINT_SUPPLY_WAD / (10 ** (18 - decimals_));
    }

    function mint(address to, uint256 amount) external {
        require(to != address(0), "ERC20: mint to zero");
        require(amount > 0 && totalSupply + amount <= maxRawSupply, "ERC20: supply cap exceeded");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        require(spender != address(0), "ERC20: approve to zero");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        require(to != address(0), "ERC20: transfer to zero");
        require(balanceOf[msg.sender] >= value, "ERC20: insufficient balance");
        unchecked {
            balanceOf[msg.sender] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        require(to != address(0), "ERC20: transfer to zero");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "ERC20: insufficient allowance");
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        require(balanceOf[from] >= value, "ERC20: insufficient balance");
        unchecked {
            balanceOf[from] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}
