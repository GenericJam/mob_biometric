defmodule MobBiometric.DemoScreen do
  @moduledoc """
  A ready-to-run sample screen exercising `MobBiometric`, shipped so a generated
  app can kick the tires the moment the plugin is activated. Declared in the
  plugin manifest's `:screens`, so the host's home can surface it by route
  without writing any code. Delete it (and the manifest entry) in a real app.
  """
  use Mob.Screen

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Mob.Socket.assign(socket, status: "Tap to authenticate")}
  end

  @impl true
  def render(assigns) do
    tap_auth = {self(), :authenticate}

    ~MOB"""
    <Scroll background={:background}>
      <Column background={:background} padding={:space_lg}>
        <Text text="Biometric" text_size={:lg} text_color={:on_surface} padding={:space_sm} />
        <Text text={assigns.status} text_size={:sm} text_color={:primary} padding={4} />
        <Spacer size={16} />
        <Button text="Authenticate" background={:primary} text_color={:on_primary} padding={:space_md} fill_width={true} on_tap={tap_auth} />
      </Column>
    </Scroll>
    """
  end

  @impl true
  def handle_info({:tap, :authenticate}, socket) do
    {:noreply,
     MobBiometric.authenticate(socket, reason: "Confirm it's you")
     |> Mob.Socket.assign(status: "Prompting…")}
  end

  def handle_info({:biometric, :success}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Authenticated ✓")}
  end

  def handle_info({:biometric, :failure}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Authentication failed")}
  end

  def handle_info({:biometric, :not_available}, socket) do
    {:noreply, Mob.Socket.assign(socket, status: "Biometrics not available on this device")}
  end
end
