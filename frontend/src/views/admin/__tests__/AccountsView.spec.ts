import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { defineComponent } from 'vue'

const mockAccountsList = vi.fn()
const mockGetBatchTodayStats = vi.fn()
const mockProxiesGetAll = vi.fn()
const mockGroupsGetAll = vi.fn()

vi.mock('@/api/admin', () => ({
  adminAPI: {
    accounts: {
      list: (...args: any[]) => mockAccountsList(...args),
      getBatchTodayStats: (...args: any[]) => mockGetBatchTodayStats(...args),
      listWithEtag: vi.fn(),
      delete: vi.fn(),
      bulkUpdate: vi.fn(),
      exportData: vi.fn(),
      getAvailableModels: vi.fn(),
      refreshCredentials: vi.fn(),
      clearError: vi.fn(),
      clearRateLimit: vi.fn(),
      resetAccountQuota: vi.fn(),
      setSchedulable: vi.fn(),
    },
    proxies: {
      getAll: (...args: any[]) => mockProxiesGetAll(...args),
    },
    groups: {
      getAll: (...args: any[]) => mockGroupsGetAll(...args),
    },
  },
}))

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({
    showSuccess: vi.fn(),
    showError: vi.fn(),
  }),
}))

vi.mock('@/stores/auth', () => ({
  useAuthStore: () => ({
    isSimpleMode: false,
  }),
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key,
    }),
  }
})

const SimpleStub = defineComponent({
  template: '<div><slot /></div>',
})

const TablePageLayoutStub = defineComponent({
  template: `
    <div>
      <slot name="filters" />
      <slot name="table" />
      <slot name="pagination" />
    </div>
  `,
})

const DataTableStub = defineComponent({
  props: {
    data: {
      type: Array,
      default: () => [],
    },
  },
  template: `
    <div>
      <div v-for="row in data" :key="row.id" class="row">
        <slot name="cell-platform_type" :row="row" :value="row.platform" />
      </div>
    </div>
  `,
})

const PaginationStub = defineComponent({
  props: {
    pageSizeOptions: {
      type: Array,
      default: () => [],
    },
  },
  template: '<div class="pagination-stub">{{ JSON.stringify(pageSizeOptions) }}</div>',
})

const SearchInputStub = defineComponent({
  props: {
    modelValue: {
      type: String,
      default: '',
    },
  },
  emits: ['update:modelValue', 'search'],
  template: `
    <div class="search-input-stub">
      <input
        data-test="search-input"
        :value="modelValue"
        @input="$emit('update:modelValue', $event.target.value)"
      />
    </div>
  `,
})

const SelectStub = defineComponent({
  props: {
    modelValue: {
      default: '',
    },
    options: {
      type: Array,
      default: () => [],
    },
  },
  emits: ['update:modelValue', 'change'],
  template: `
    <div class="select-stub">
      <span>{{ modelValue }}</span>
      <span>{{ options.length }}</span>
    </div>
  `,
})

let toolbarRowWidth = 1100
const toolbarItemWidths: Record<string, number> = {
  search: 180,
  platform: 120,
  type: 120,
  status: 120,
  group: 120,
  refresh: 90,
  export: 100,
  create: 120,
  more: 90,
}
const toolbarGap = 8

Object.defineProperty(HTMLElement.prototype, 'clientWidth', {
  configurable: true,
  get() {
    const role = this.getAttribute?.('data-toolbar-role')
    if (role === 'row') return toolbarRowWidth
    const item = this.getAttribute?.('data-toolbar-item')
    return item ? toolbarItemWidths[item] ?? 0 : 0
  },
})

Object.defineProperty(HTMLElement.prototype, 'scrollWidth', {
  configurable: true,
  get() {
    const role = this.getAttribute?.('data-toolbar-role')
    if (role === 'row') {
      const children = Array.from(this.children).filter((child): child is HTMLElement =>
        child instanceof HTMLElement && !!child.getAttribute('data-toolbar-item')
      )
      const contentWidth = children.reduce((total, child) => {
        const item = child.getAttribute('data-toolbar-item') ?? ''
        return total + (toolbarItemWidths[item] ?? 0)
      }, 0) + Math.max(0, children.length - 1) * toolbarGap
      return Math.max(toolbarRowWidth, contentWidth)
    }
    const item = this.getAttribute?.('data-toolbar-item')
    return item ? toolbarItemWidths[item] ?? 0 : 0
  },
})

HTMLElement.prototype.getBoundingClientRect = function getBoundingClientRect() {
  const item = this.getAttribute?.('data-toolbar-item')
  if (item) {
    const width = toolbarItemWidths[item] ?? 0
    return {
      width,
      height: 40,
      top: 24,
      right: 24 + width,
      bottom: 64,
      left: 24,
      x: 24,
      y: 24,
      toJSON: () => ({}),
    } as DOMRect
  }

  if (this.getAttribute?.('title') === 'common.more') {
    return {
      width: 90,
      height: 40,
      top: 24,
      right: 114,
      bottom: 64,
      left: 24,
      x: 24,
      y: 24,
      toJSON: () => ({}),
    } as DOMRect
  }

  return {
    width: 0,
    height: 0,
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    x: 0,
    y: 0,
    toJSON: () => ({}),
  } as DOMRect
}

class ResizeObserverStub {
  callback: ResizeObserverCallback

  constructor(callback: ResizeObserverCallback) {
    this.callback = callback
  }

  observe(target: Element) {
    this.callback([{ target } as ResizeObserverEntry], this as unknown as ResizeObserver)
  }

  unobserve() {}

  disconnect() {}
}

vi.stubGlobal('ResizeObserver', ResizeObserverStub)

import AccountsView from '../AccountsView.vue'

describe('AccountsView', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    localStorage.clear()
    toolbarRowWidth = 1100

    mockAccountsList.mockResolvedValue({
      items: [
        {
          id: 101,
          name: 'OpenAI OAuth Account',
          notes: null,
          platform: 'openai',
          type: 'oauth',
          credentials: {
            plan_type: 'chatgptpro',
          },
          extra: {},
          concurrency: 1,
          priority: 10,
          rate_multiplier: 1,
          status: 'active',
          error_message: '',
          last_used_at: null,
          expires_at: null,
          auto_pause_on_expired: false,
          created_at: '2026-03-10T00:00:00Z',
          updated_at: '2026-03-10T00:00:00Z',
          schedulable: true,
          groups: [],
        },
      ],
      total: 1,
      page: 1,
      page_size: 20,
      pages: 1,
    })
    mockGetBatchTodayStats.mockResolvedValue({ stats: {} })
    mockProxiesGetAll.mockResolvedValue([])
    mockGroupsGetAll.mockResolvedValue([])
  })

  it('renders the normalized OpenAI plan type badge in account rows', async () => {
    const wrapper = mount(AccountsView, {
      global: {
        stubs: {
          AppLayout: SimpleStub,
          TablePageLayout: TablePageLayoutStub,
          AccountBulkActionsBar: true,
          DataTable: DataTableStub,
          Pagination: PaginationStub,
          SearchInput: SearchInputStub,
          Select: SelectStub,
          CreateAccountModal: true,
          EditAccountModal: true,
          ReAuthAccountModal: true,
          AccountTestModal: true,
          AccountStatsModal: true,
          ScheduledTestsPanel: true,
          AccountActionMenu: true,
          SyncFromCrsModal: true,
          ImportDataModal: true,
          BulkEditAccountModal: true,
          TempUnschedStatusModal: true,
          ConfirmDialog: true,
          ErrorPassthroughRulesModal: true,
          AccountStatusIndicator: true,
          AccountUsageCell: true,
          AccountTodayStatsCell: true,
          AccountGroupsCell: true,
          AccountCapacityCell: true,
          PlatformIcon: true,
          Icon: true,
        },
      },
    })

    await flushPromises()
    await flushPromises()

    expect(mockAccountsList).toHaveBeenCalledTimes(1)
    expect(wrapper.text()).toContain('OpenAI')
    expect(wrapper.text()).toContain('OAuth')
    expect(wrapper.text()).toContain('Pro')
    expect(wrapper.find('.pagination-stub').text()).toContain('[5,10,20,50,100]')
  })

  it('moves secondary toolbar actions into the more menu', async () => {
    const wrapper = mount(AccountsView, {
      global: {
        stubs: {
          AppLayout: SimpleStub,
          TablePageLayout: TablePageLayoutStub,
          AccountBulkActionsBar: true,
          DataTable: DataTableStub,
          Pagination: PaginationStub,
          SearchInput: SearchInputStub,
          Select: SelectStub,
          CreateAccountModal: true,
          EditAccountModal: true,
          ReAuthAccountModal: true,
          AccountTestModal: true,
          AccountStatsModal: true,
          ScheduledTestsPanel: true,
          AccountActionMenu: true,
          SyncFromCrsModal: true,
          ImportDataModal: true,
          BulkEditAccountModal: true,
          TempUnschedStatusModal: true,
          ConfirmDialog: true,
          ErrorPassthroughRulesModal: true,
          AccountStatusIndicator: true,
          AccountUsageCell: true,
          AccountTodayStatsCell: true,
          AccountGroupsCell: true,
          AccountCapacityCell: true,
          PlatformIcon: true,
          Icon: true,
        },
      },
    })

    await flushPromises()
    await flushPromises()

    expect(wrapper.text()).not.toContain('admin.accounts.dataImport')
    expect(wrapper.text()).not.toContain('admin.errorPassthrough.title')

    await wrapper.get('button[title="common.more"]').trigger('click')

    expect(wrapper.text()).toContain('admin.accounts.dataImport')
    expect(wrapper.text()).toContain('admin.errorPassthrough.title')
    expect(wrapper.text()).toContain('admin.accounts.autoRefresh')
    expect(wrapper.text()).toContain('admin.users.columnSettings')
    expect(wrapper.get('[data-testid="accounts-more-menu"]').classes()).toContain('fixed')
    expect(wrapper.get('[data-testid="accounts-more-menu"]').attributes('style')).toContain('top:')
  })

  it('moves rightmost toolbar items into more when the row width is constrained', async () => {
    toolbarRowWidth = 680

    const wrapper = mount(AccountsView, {
      global: {
        stubs: {
          AppLayout: SimpleStub,
          TablePageLayout: TablePageLayoutStub,
          AccountBulkActionsBar: true,
          DataTable: DataTableStub,
          Pagination: PaginationStub,
          SearchInput: SearchInputStub,
          Select: SelectStub,
          CreateAccountModal: true,
          EditAccountModal: true,
          ReAuthAccountModal: true,
          AccountTestModal: true,
          AccountStatsModal: true,
          ScheduledTestsPanel: true,
          AccountActionMenu: true,
          SyncFromCrsModal: true,
          ImportDataModal: true,
          BulkEditAccountModal: true,
          TempUnschedStatusModal: true,
          ConfirmDialog: true,
          ErrorPassthroughRulesModal: true,
          AccountStatusIndicator: true,
          AccountUsageCell: true,
          AccountTodayStatsCell: true,
          AccountGroupsCell: true,
          AccountCapacityCell: true,
          PlatformIcon: true,
          Icon: true,
        },
      },
    })

    await flushPromises()
    await flushPromises()

    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="platform"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="type"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="status"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="group"]').exists()).toBe(false)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="refresh"]').exists()).toBe(false)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="export"]').exists()).toBe(false)
    expect(wrapper.find('[data-toolbar-slot="main"][data-toolbar-item="create"]').exists()).toBe(false)

    await wrapper.get('button[title="common.more"]').trigger('click')

    expect(wrapper.find('[data-toolbar-slot="overflow"][data-toolbar-item="group"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="overflow"][data-toolbar-item="refresh"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="overflow"][data-toolbar-item="export"]').exists()).toBe(true)
    expect(wrapper.find('[data-toolbar-slot="overflow"][data-toolbar-item="create"]').exists()).toBe(true)
  })
})
