<script>
  import { onMount } from 'svelte';
  import { currentUser, isAuthenticated, currentPage, toast, initRouter, navigate, showToast } from './lib/store.js';
  import { api } from './lib/api.js';
  import Login from './pages/Login.svelte';
  import Register from './pages/Register.svelte';
  import Dashboard from './pages/Dashboard.svelte';
  import Users from './pages/Users.svelte';
  import Devices from './pages/Devices.svelte';
  import Sidebar from './components/Sidebar.svelte';
  import Toast from './components/Toast.svelte';

  onMount(async () => {
    initRouter();
    try {
      const data = await api.me();
      currentUser.set(data.user || data);
      isAuthenticated.set(true);
      if ($currentPage === 'login' || $currentPage === 'register') {
        navigate('dashboard');
      }
    } catch {
      isAuthenticated.set(false);
      if ($currentPage !== 'register') navigate('login');
    }
  });

  $: if (!$isAuthenticated && $currentPage !== 'login' && $currentPage !== 'register') {
    navigate('login');
  }
</script>

<Toast />

{#if !$isAuthenticated}
  {#if $currentPage === 'register'}
    <Register />
  {:else}
    <Login />
  {/if}
{:else}
  <div class="flex h-screen">
    <Sidebar />
    <main class="flex-1 overflow-auto p-6 bg-gray-50">
      {#if $currentPage === 'dashboard'}
        <Dashboard />
      {:else if $currentPage === 'users'}
        <Users />
      {:else if $currentPage === 'devices'}
        <Devices />
      {/if}
    </main>
  </div>
{/if}
