// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISpl20 {
    function mintTokens(address to, address mintAddr, uint256 amount) external;
    function transfer(address to, address mintAddr, uint256 amount) external;
    function getMint(address mintAddr) external view returns (uint8, uint256, address, address, address);
    function getTokenAccount(address owner, address mintAddr) external view returns (address, address, uint256, bool);
}

contract Spl4626Vault {
    ISpl20  public immutable spl20;
    address public immutable mintAddr;
    uint8   public immutable assetDecimals;
    uint256 public totalShareSupply;

    mapping(address => uint256) public shareBalance;
    mapping(address => mapping(address => uint256)) public shareAllowance;

    bool private locked;

    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    modifier nonReentrant() {
        require(!locked, "REENTRANCY");
        locked = true;
        _;
        locked = false;
    }

    constructor(ISpl20 _spl20, address _mintAddr) {
        spl20 = _spl20;
        mintAddr = _mintAddr;
        (uint8 dec,, , ,) = _spl20.getMint(_mintAddr);
        assetDecimals = dec;
    }

    function totalAssets() public view returns (uint256 assets) {
        (, , assets, ) = spl20.getTokenAccount(address(this), mintAddr);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return totalShareSupply == 0 ? assets : (assets * totalShareSupply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalShareSupply == 0 ? shares : (shares * totalAssets()) / totalShareSupply;
    }

    function _mint(address to, uint256 amount) internal {
        totalShareSupply += amount;
        shareBalance[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        shareBalance[from] -= amount;
        totalShareSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        shareAllowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        spl20.transfer(address(this), mintAddr, assets);
        shares = convertToShares(assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        if (msg.sender != owner) {
            uint256 allowed = shareAllowance[owner][msg.sender];
            require(allowed >= shares, "allowance too low");
            if (allowed != type(uint256).max) {
                shareAllowance[owner][msg.sender] = allowed - shares;
            }
        }
        assets = convertToAssets(shares);
        _burn(owner, shares);
        spl20.transfer(receiver, mintAddr, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }
}
