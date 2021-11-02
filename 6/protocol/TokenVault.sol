// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../utils/SafeToken.sol";

// Claimable
// Extension for the Ownable contract, where the ownership needs to be claimed.
// This allows the new owner to accept the transfer.
contract Claimable is OwnableUpgradeSafe {
  address public pendingOwner;

  constructor() public {
    OwnableUpgradeSafe.__Ownable_init();
  }

  /**
   * @dev Modifier throws if called by any account other than the pendingOwner.
   */
  modifier onlyPendingOwner() {
    require(msg.sender == pendingOwner);
    _;
  }

  /**
   * @dev Allows the current owner to set the pendingOwner address.
   * @param newOwner The address to transfer ownership to.
   */
  function transferOwnership(address newOwner) public override onlyOwner {
    pendingOwner = newOwner;
  }

  /**
   * @dev Allows the pendingOwner address to finalize the transfer.
   */
  function claimOwnership() public onlyPendingOwner {
    transferOwnership(pendingOwner);
    pendingOwner = address(0);
  }
}

// Roles
library Roles {
  struct Role {
    mapping (address => bool) bearer;
  }

  /**
   * @dev give an address access to this role
   */
  function add(Role storage _role, address _addr)
    internal
  {
    _role.bearer[_addr] = true;
  }

  /**
   * @dev remove an address' access to this role
   */
  function remove(Role storage _role, address _addr)
    internal
  {
    _role.bearer[_addr] = false;
  }

  /**
   * @dev check if an address has this role
   * // reverts
   */
  function check(Role storage _role, address _addr)
    internal
    view
  {
    require(has(_role, _addr), "not permit role");
  }

  /**
   * @dev check if an address has this role
   * @return bool
   */
  function has(Role storage _role, address _addr)
    internal
    view
    returns (bool)
  {
    return _role.bearer[_addr];
  }
}

// RBAC (Role-Based Access Control)
// Stores and provides setters and getters for roles and addresses.
// Supports unlimited numbers of roles and addresses.
// See //contracts/mocks/RBACMock.sol for an example of usage.
// This RBAC method uses strings to key roles. It may be beneficial
// for you to write your own implementation of this interface using Enums or similar.
contract RBAC {
  using Roles for Roles.Role;

  mapping (string => Roles.Role) private roles;

  event RoleAdded(address indexed operator, string role);
  event RoleRemoved(address indexed operator, string role);

  /**
   * @dev reverts if addr does not have role
   * @param _operator address
   * @param _role the name of the role
   * // reverts
   */
  function checkRole(address _operator, string memory _role)
    public
    view
  {
    roles[_role].check(_operator);
  }

  /**
   * @dev determine if addr has role
   * @param _operator address
   * @param _role the name of the role
   * @return bool
   */
  function hasRole(address _operator, string memory _role)
    public
    view
    returns (bool)
  {
    return roles[_role].has(_operator);
  }

  /**
   * @dev add a role to an address
   * @param _operator address
   * @param _role the name of the role
   */
  function addRole(address _operator, string memory _role)
    internal
  {
    roles[_role].add(_operator);
    emit RoleAdded(_operator, _role);
  }

  /**
   * @dev remove a role from an address
   * @param _operator address
   * @param _role the name of the role
   */
  function removeRole(address _operator, string memory _role)
    internal
  {
    roles[_role].remove(_operator);
    emit RoleRemoved(_operator, _role);
  }

  /**
   * @dev modifier to scope access to a single role (uses msg.sender as addr)
   * @param _role the name of the role
   * // reverts
   */
  modifier onlyRole(string memory _role)
  {
    checkRole(msg.sender, _role);
    _;
  }
}

/**
 * @title Whitelist
 * @dev A minimal, simple database mapping public addresses (ie users) to their permissions.
 *
 * `TokenizedProperty` references `this` to only allow tokens to be transferred to addresses with necessary permissions.
 * `TokenSale` references `this` to only allow tokens to be purchased by addresses within the necessary permissions.
 *
 * `WhitelistProxy` enables `this` to be easily and reliably upgraded if absolutely necessary.
 * `WhitelistProxy` and `this` are controlled by a centralized entity (blockimmo).
 *  This centralization is required by our legal framework to ensure investors are known and fully-legal.
 */
contract Whitelist is Claimable, RBAC {
  function grantPermission(address _operator, string memory _permission) public onlyOwner {
    addRole(_operator, _permission);
  }

  function revokePermission(address _operator, string memory _permission) public onlyOwner {
    removeRole(_operator, _permission);
  }

  function grantPermissionBatch(address[] memory _operators, string memory _permission) public onlyOwner {
    for (uint256 i = 0; i < _operators.length; i++) {
      addRole(_operators[i], _permission);
    }
  }

  function revokePermissionBatch(address[] memory _operators, string memory _permission) public onlyOwner {
    for (uint256 i = 0; i < _operators.length; i++) {
      removeRole(_operators[i], _permission);
    }
  }
}

contract TokenVault is ReentrancyGuardUpgradeSafe, Whitelist {
  using SafeToken for address;

  string public constant WORKER_ROLE = "AmyWorker";

  function withdraw(address _token, uint256 _amount, address _receiver)
    external onlyRole(WORKER_ROLE)
  {
    require(_receiver != address(0), "Illegal amount" );
    require(SafeToken.balanceOf(_token, address(this)) >= _amount, "Illegal Amount");

    SafeToken.safeTransfer(_token, _receiver, _amount);
  }

  function deposit(address _token, uint _amount) external {
    require(_token != address(0), "token address is zero" );
    SafeToken.safeTransferFrom(_token, msg.sender, address(this), _amount);
  }

}