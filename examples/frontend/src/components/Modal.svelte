<script>
  import { createEventDispatcher } from 'svelte';
  export let show = false;
  export let title = '';
  const dispatch = createEventDispatcher();
</script>

{#if show}
  <div class="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50" on:click={() => dispatch('close')}>
    <div class="bg-white rounded-xl shadow-xl w-full max-w-md mx-4" on:click|stopPropagation>
      <div class="px-6 py-4 border-b border-gray-200">
        <h3 class="text-lg font-semibold text-gray-900">{title}</h3>
      </div>
      <div class="px-6 py-4">
        <slot />
      </div>
      <div class="px-6 py-4 border-t border-gray-200 flex justify-end gap-3">
        <slot name="actions" />
      </div>
    </div>
  </div>
{/if}
