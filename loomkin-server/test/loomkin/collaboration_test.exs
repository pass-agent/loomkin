defmodule Loomkin.CollaborationTest do
  use Loomkin.DataCase, async: true

  alias Loomkin.Collaboration
  alias Loomkin.Schemas.WorkspaceInvite
  alias Loomkin.Schemas.WorkspaceMembership
  alias Loomkin.Workspace

  import Loomkin.AccountsFixtures

  defp insert_membership(workspace_id, user_id, attrs \\ %{}) do
    %WorkspaceMembership{}
    |> WorkspaceMembership.changeset(Map.put_new(attrs, :role, :collaborator))
    |> Ecto.Changeset.put_change(:workspace_id, workspace_id)
    |> Ecto.Changeset.put_change(:user_id, user_id)
    |> Repo.insert()
  end

  defp create_workspace(user) do
    {:ok, %{workspace: workspace}} =
      Collaboration.create_workspace_with_owner(
        %{name: "test-workspace-#{System.unique_integer()}"},
        user.id
      )

    workspace
  end

  defp owner_scope(user) do
    Loomkin.Accounts.Scope.for_user(user)
  end

  describe "create_invite/3" do
    test "creates an invite when called by workspace owner" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      assert {:ok, %WorkspaceInvite{} = invite} =
               Collaboration.create_invite(scope, workspace.id, %{
                 email: "friend@example.com",
                 role: :collaborator
               })

      assert invite.email == "friend@example.com"
      assert invite.role == :collaborator
      assert invite.status == :pending
      assert invite.workspace_id == workspace.id
      assert invite.invited_by_id == owner.id
      assert is_binary(invite.token)
      assert byte_size(invite.token) > 20
      assert invite.expires_at != nil
    end

    test "rejects invite from non-owner" do
      owner = user_fixture()
      other_user = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(other_user)

      assert {:error, :unauthorized} =
               Collaboration.create_invite(scope, workspace.id, %{
                 email: "friend@example.com",
                 role: :collaborator
               })
    end

    test "rejects invite for non-existent workspace" do
      owner = user_fixture()
      scope = owner_scope(owner)
      fake_id = Ecto.UUID.generate()

      assert {:error, :workspace_not_found} =
               Collaboration.create_invite(scope, fake_id, %{
                 email: "friend@example.com",
                 role: :collaborator
               })
    end

    test "rejects duplicate pending invite to same email" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)
      attrs = %{email: "friend@example.com", role: :collaborator}

      assert {:ok, _invite} = Collaboration.create_invite(scope, workspace.id, attrs)
      assert {:error, :duplicate_invite} = Collaboration.create_invite(scope, workspace.id, attrs)
    end

    test "allows re-invite after previous invite was declined" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)
      attrs = %{email: "friend@example.com", role: :collaborator}

      assert {:ok, invite} = Collaboration.create_invite(scope, workspace.id, attrs)
      assert {:ok, _declined} = Collaboration.decline_invite(invite.token)
      assert {:ok, _new_invite} = Collaboration.create_invite(scope, workspace.id, attrs)
    end

    test "invite token is unique and cryptographically random" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite1} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "a@example.com",
          role: :collaborator
        })

      {:ok, invite2} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "b@example.com",
          role: :observer
        })

      refute invite1.token == invite2.token
    end

    test "rejects invite with nil scope" do
      assert {:error, :unauthenticated} =
               Collaboration.create_invite(nil, Ecto.UUID.generate(), %{
                 email: "x@example.com",
                 role: :collaborator
               })
    end
  end

  describe "accept_invite/1" do
    test "accepting invite creates membership" do
      owner = user_fixture()
      invitee = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: invitee.email,
          role: :collaborator
        })

      assert {:ok, %WorkspaceMembership{} = membership} =
               Collaboration.accept_invite(invite.token)

      assert membership.workspace_id == workspace.id
      assert membership.user_id == invitee.id
      assert membership.role == :collaborator
      assert membership.invited_by_id == owner.id
      assert membership.accepted_at != nil

      # Invite should be marked accepted
      updated_invite = Repo.get!(WorkspaceInvite, invite.id)
      assert updated_invite.status == :accepted
    end

    test "expired invite cannot be accepted" do
      owner = user_fixture()
      invitee = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: invitee.email,
          role: :collaborator
        })

      # Expire the invite manually
      invite
      |> Ecto.Changeset.change(
        expires_at:
          DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :invite_expired} = Collaboration.accept_invite(invite.token)
    end

    test "cannot accept already-accepted invite" do
      owner = user_fixture()
      invitee = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: invitee.email,
          role: :collaborator
        })

      assert {:ok, _membership} = Collaboration.accept_invite(invite.token)
      assert {:error, :invite_not_found} = Collaboration.accept_invite(invite.token)
    end

    test "cannot accept invite if already a member" do
      owner = user_fixture()
      invitee = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      # Create collaborator membership first
      {:ok, _membership} = insert_membership(workspace.id, invitee.id)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: invitee.email,
          role: :collaborator
        })

      assert {:error, :already_a_member} = Collaboration.accept_invite(invite.token)
    end

    test "returns error for invalid token" do
      assert {:error, :invalid_token} = Collaboration.accept_invite(nil)
      assert {:error, :invite_not_found} = Collaboration.accept_invite("nonexistent-token")
    end

    test "returns error when invitee user does not exist" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "nobody@nowhere.com",
          role: :collaborator
        })

      assert {:error, :user_not_found} = Collaboration.accept_invite(invite.token)
    end
  end

  describe "decline_invite/1" do
    test "marks invite as declined" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "friend@example.com",
          role: :collaborator
        })

      assert {:ok, declined} = Collaboration.decline_invite(invite.token)
      assert declined.status == :declined
    end

    test "returns error for non-existent token" do
      assert {:error, :invite_not_found} = Collaboration.decline_invite("bad-token")
    end
  end

  describe "revoke_invite/2" do
    test "owner can revoke a pending invite" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, invite} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "friend@example.com",
          role: :collaborator
        })

      assert {:ok, revoked} = Collaboration.revoke_invite(scope, invite.id)
      assert revoked.status == :revoked
    end

    test "non-owner cannot revoke" do
      owner = user_fixture()
      other = user_fixture()
      workspace = create_workspace(owner)
      owner_sc = owner_scope(owner)
      other_sc = owner_scope(other)

      {:ok, invite} =
        Collaboration.create_invite(owner_sc, workspace.id, %{
          email: "friend@example.com",
          role: :collaborator
        })

      assert {:error, :unauthorized} = Collaboration.revoke_invite(other_sc, invite.id)
    end
  end

  describe "list_pending_invites/1" do
    test "returns only pending invites for the workspace" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, _invite1} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "a@example.com",
          role: :collaborator
        })

      {:ok, invite2} =
        Collaboration.create_invite(scope, workspace.id, %{
          email: "b@example.com",
          role: :observer
        })

      # Decline one
      Collaboration.decline_invite(invite2.token)

      assert {:ok, pending} = Collaboration.list_pending_invites(scope, workspace.id)
      assert length(pending) == 1
      assert hd(pending).email == "a@example.com"
    end
  end

  describe "list_members/2" do
    test "returns all members with preloaded users" do
      owner = user_fixture()
      member = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      # Owner membership already created by create_workspace; add a collaborator
      {:ok, _} = insert_membership(workspace.id, member.id, %{invited_by_id: owner.id})

      assert {:ok, members} = Collaboration.list_members(scope, workspace.id)
      assert length(members) == 2
      assert Enum.all?(members, fn m -> m.user != nil end)
    end
  end

  describe "update_member_role/3" do
    test "owner can change a collaborator to observer" do
      owner = user_fixture()
      member = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, membership} =
        insert_membership(workspace.id, member.id, %{invited_by_id: owner.id})

      assert {:ok, updated} = Collaboration.update_member_role(scope, membership.id, :observer)
      assert updated.role == :observer
    end

    test "non-owner cannot change roles" do
      owner = user_fixture()
      member = user_fixture()
      other = user_fixture()
      workspace = create_workspace(owner)
      other_scope = owner_scope(other)

      {:ok, membership} = insert_membership(workspace.id, member.id)

      assert {:error, :unauthorized} =
               Collaboration.update_member_role(other_scope, membership.id, :observer)
    end

    test "cannot change owner's role" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      owner_membership = Collaboration.get_membership(workspace.id, owner.id)

      assert {:error, :cannot_change_owner_role} =
               Collaboration.update_member_role(scope, owner_membership.id, :collaborator)
    end
  end

  describe "remove_member/2" do
    test "owner can remove a collaborator" do
      owner = user_fixture()
      member = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      {:ok, membership} = insert_membership(workspace.id, member.id)

      assert {:ok, _deleted} = Collaboration.remove_member(scope, membership.id)
      assert Collaboration.get_membership(workspace.id, member.id) == nil
    end

    test "member can leave (remove themselves)" do
      owner = user_fixture()
      member = user_fixture()
      workspace = create_workspace(owner)
      member_scope = owner_scope(member)

      {:ok, membership} = insert_membership(workspace.id, member.id)

      assert {:ok, _deleted} = Collaboration.remove_member(member_scope, membership.id)
      assert Collaboration.get_membership(workspace.id, member.id) == nil
    end

    test "owner cannot be removed" do
      owner = user_fixture()
      workspace = create_workspace(owner)
      scope = owner_scope(owner)

      owner_membership = Collaboration.get_membership(workspace.id, owner.id)

      assert {:error, :cannot_remove_owner} =
               Collaboration.remove_member(scope, owner_membership.id)
    end

    test "non-owner non-self cannot remove others" do
      owner = user_fixture()
      member = user_fixture()
      other = user_fixture()
      workspace = create_workspace(owner)
      other_scope = owner_scope(other)

      {:ok, membership} = insert_membership(workspace.id, member.id)

      assert {:error, :unauthorized} = Collaboration.remove_member(other_scope, membership.id)
    end
  end

  describe "authorize/3" do
    test "owner can do everything" do
      owner = user_fixture()
      workspace = create_workspace(owner)

      for action <- [
            :view,
            :send_message,
            :approve_tool,
            :manage_agents,
            :manage_members,
            :delete_workspace
          ] do
        assert :ok == Collaboration.authorize(owner.id, workspace.id, action),
               "owner should be authorized for #{action}"
      end
    end

    test "collaborator can view and act but not manage members" do
      owner = user_fixture()
      collab = user_fixture()
      workspace = create_workspace(owner)

      {:ok, _} = insert_membership(workspace.id, collab.id)

      assert :ok == Collaboration.authorize(collab.id, workspace.id, :view)
      assert :ok == Collaboration.authorize(collab.id, workspace.id, :send_message)
      assert :ok == Collaboration.authorize(collab.id, workspace.id, :approve_tool)
      assert :ok == Collaboration.authorize(collab.id, workspace.id, :manage_agents)

      assert {:error, :unauthorized} ==
               Collaboration.authorize(collab.id, workspace.id, :manage_members)

      assert {:error, :unauthorized} ==
               Collaboration.authorize(collab.id, workspace.id, :delete_workspace)
    end

    test "observer can only view" do
      owner = user_fixture()
      observer = user_fixture()
      workspace = create_workspace(owner)

      {:ok, _} = insert_membership(workspace.id, observer.id, %{role: :observer})

      assert :ok == Collaboration.authorize(observer.id, workspace.id, :view)

      assert {:error, :unauthorized} ==
               Collaboration.authorize(observer.id, workspace.id, :send_message)

      assert {:error, :unauthorized} ==
               Collaboration.authorize(observer.id, workspace.id, :manage_members)
    end

    test "workspace owner is authorized via membership row" do
      owner = user_fixture()
      workspace = create_workspace(owner)

      # Owner membership is created atomically with workspace
      assert :ok == Collaboration.authorize(owner.id, workspace.id, :view)
      assert :ok == Collaboration.authorize(owner.id, workspace.id, :delete_workspace)
    end

    test "workspace owner without membership row is unauthorized" do
      owner = user_fixture()

      # Bypass the atomic creation to simulate a missing membership
      {:ok, workspace} =
        %Workspace{}
        |> Workspace.changeset(%{
          name: "orphan-workspace-#{System.unique_integer()}",
          user_id: owner.id
        })
        |> Repo.insert()

      assert {:error, :unauthorized} == Collaboration.authorize(owner.id, workspace.id, :view)
    end

    test "non-member is unauthorized" do
      owner = user_fixture()
      stranger = user_fixture()
      workspace = create_workspace(owner)

      assert {:error, :unauthorized} == Collaboration.authorize(stranger.id, workspace.id, :view)
    end
  end

  describe "member?/2" do
    test "returns true for members, false for non-members" do
      owner = user_fixture()
      member = user_fixture()
      stranger = user_fixture()
      workspace = create_workspace(owner)

      {:ok, _} = insert_membership(workspace.id, member.id)

      assert Collaboration.member?(owner.id, workspace.id)
      assert Collaboration.member?(member.id, workspace.id)
      refute Collaboration.member?(stranger.id, workspace.id)
    end
  end
end
