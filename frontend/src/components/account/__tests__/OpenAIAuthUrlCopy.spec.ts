import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { defineComponent } from 'vue'

const mocks = vi.hoisted(() => {
  const createOAuthClient = () => ({
    authUrl: { value: '' },
    sessionId: { value: '' },
    oauthState: { value: '' },
    loading: { value: false },
    error: { value: '' },
    generateAuthUrl: vi.fn(),
    exchangeAuthCode: vi.fn(),
    validateRefreshToken: vi.fn(),
    validateSessionToken: vi.fn(),
    buildCredentials: vi.fn(),
    buildExtraInfo: vi.fn(),
    resetState: vi.fn()
  })

  return {
    openaiOAuth: createOAuthClient(),
    soraOAuth: createOAuthClient(),
    geminiOAuth: createOAuthClient(),
    antigravityOAuth: createOAuthClient(),
    claudeOAuth: {
      authUrl: { value: '' },
      sessionId: { value: '' },
      loading: { value: false },
      error: { value: '' },
      generateAuthUrl: vi.fn(),
      exchangeCode: vi.fn(),
      completeCookieAuth: vi.fn(),
      resetState: vi.fn()
    },
    copyToClipboard: vi.fn()
  }
})

vi.mock('@/stores/app', () => ({
  useAppStore: () => ({
    showError: vi.fn(),
    showSuccess: vi.fn(),
    showInfo: vi.fn()
  })
}))

vi.mock('@/stores/auth', () => ({
  useAuthStore: () => ({
    isSimpleMode: false
  })
}))

vi.mock('@/composables/useClipboard', () => ({
  useClipboard: () => ({
    copied: { value: false },
    copyToClipboard: mocks.copyToClipboard
  })
}))

vi.mock('@/composables/useOpenAIOAuth', () => ({
  useOpenAIOAuth: (options?: { platform?: 'openai' | 'sora' }) =>
    options?.platform === 'sora' ? mocks.soraOAuth : mocks.openaiOAuth
}))

vi.mock('@/composables/useGeminiOAuth', () => ({
  useGeminiOAuth: () => mocks.geminiOAuth
}))

vi.mock('@/composables/useAntigravityOAuth', () => ({
  useAntigravityOAuth: () => mocks.antigravityOAuth
}))

vi.mock('@/composables/useAccountOAuth', () => ({
  useAccountOAuth: () => mocks.claudeOAuth
}))

vi.mock('vue-i18n', async () => {
  const actual = await vi.importActual<typeof import('vue-i18n')>('vue-i18n')
  return {
    ...actual,
    useI18n: () => ({
      t: (key: string) => key
    })
  }
})

const BaseDialogStub = defineComponent({
  template: '<div><slot /><slot name="footer" /></div>'
})

const OAuthAuthorizationFlowStub = defineComponent({
  emits: ['generate-url'],
  template: '<button class="generate-url" @click="$emit(\'generate-url\')">generate-url</button>'
})

const globalStubs = {
  BaseDialog: BaseDialogStub,
  ConfirmDialog: true,
  Select: true,
  Icon: true,
  ProxySelector: true,
  GroupSelector: true,
  ModelWhitelistSelector: true,
  QuotaLimitCard: true,
  OAuthAuthorizationFlow: OAuthAuthorizationFlowStub
}

import CreateAccountModal from '../CreateAccountModal.vue'
import ReAuthAccountModal from '../ReAuthAccountModal.vue'

function resetOAuthClient(client: any) {
  client.authUrl.value = ''
  client.sessionId.value = ''
  client.oauthState.value = ''
  client.loading.value = false
  client.error.value = ''
  client.generateAuthUrl.mockReset()
  client.exchangeAuthCode.mockReset()
  client.validateRefreshToken.mockReset()
  client.validateSessionToken.mockReset()
  client.buildCredentials.mockReset()
  client.buildExtraInfo.mockReset()
  client.resetState.mockReset()
}

function primeOpenAIGenerate(success: boolean, authUrl = 'https://auth.openai.test/callback') {
  mocks.openaiOAuth.generateAuthUrl.mockImplementation(async () => {
    mocks.openaiOAuth.authUrl.value = success ? authUrl : ''
    return success
  })
}

function mountCreateAccountModal() {
  return mount(CreateAccountModal, {
    props: {
      show: true,
      proxies: [],
      groups: []
    } as any,
    global: {
      stubs: globalStubs
    }
  })
}

function mountReAuthAccountModal() {
  return mount(ReAuthAccountModal, {
    props: {
      show: true,
      account: {
        id: 1,
        name: 'OpenAI OAuth',
        platform: 'openai',
        type: 'oauth',
        proxy_id: 9,
        credentials: {},
        extra: {}
      }
    } as any,
    global: {
      stubs: globalStubs
    }
  })
}

describe('OpenAI auth URL auto copy', () => {
  beforeEach(() => {
    resetOAuthClient(mocks.openaiOAuth)
    resetOAuthClient(mocks.soraOAuth)
    resetOAuthClient(mocks.geminiOAuth)
    resetOAuthClient(mocks.antigravityOAuth)
    mocks.claudeOAuth.authUrl.value = ''
    mocks.claudeOAuth.sessionId.value = ''
    mocks.claudeOAuth.loading.value = false
    mocks.claudeOAuth.error.value = ''
    mocks.claudeOAuth.generateAuthUrl.mockReset()
    mocks.claudeOAuth.exchangeCode.mockReset()
    mocks.claudeOAuth.completeCookieAuth.mockReset()
    mocks.claudeOAuth.resetState.mockReset()
    mocks.copyToClipboard.mockReset()
    mocks.copyToClipboard.mockResolvedValue(true)
  })

  it('auto copies generated auth URL in create modal for OpenAI accounts', async () => {
    primeOpenAIGenerate(true, 'https://auth.openai.test/generated')

    const wrapper = mountCreateAccountModal()

    await wrapper.find('input[type="text"]').setValue('New OpenAI Account')
    const openAIButton = wrapper.findAll('button').find((button) => button.text().includes('OpenAI'))
    expect(openAIButton).toBeTruthy()
    await openAIButton!.trigger('click')
    await wrapper.find('form').trigger('submit.prevent')
    await flushPromises()

    await wrapper.find('.generate-url').trigger('click')
    await flushPromises()

    expect(mocks.openaiOAuth.generateAuthUrl).toHaveBeenCalledWith(null)
    expect(mocks.copyToClipboard).toHaveBeenCalledWith(
      'https://auth.openai.test/generated',
      'admin.accounts.oauth.authUrlCopied'
    )
  })

  it('does not copy when OpenAI auth URL generation fails in create modal', async () => {
    primeOpenAIGenerate(false)

    const wrapper = mountCreateAccountModal()

    await wrapper.find('input[type="text"]').setValue('New OpenAI Account')
    const openAIButton = wrapper.findAll('button').find((button) => button.text().includes('OpenAI'))
    expect(openAIButton).toBeTruthy()
    await openAIButton!.trigger('click')
    await wrapper.find('form').trigger('submit.prevent')
    await flushPromises()

    await wrapper.find('.generate-url').trigger('click')
    await flushPromises()

    expect(mocks.openaiOAuth.generateAuthUrl).toHaveBeenCalledWith(null)
    expect(mocks.copyToClipboard).not.toHaveBeenCalled()
  })

  it('auto copies generated auth URL in reauthorization modal for OpenAI accounts', async () => {
    primeOpenAIGenerate(true, 'https://auth.openai.test/reauth')

    const wrapper = mountReAuthAccountModal()

    await wrapper.find('.generate-url').trigger('click')
    await flushPromises()

    expect(mocks.openaiOAuth.generateAuthUrl).toHaveBeenCalledWith(9)
    expect(mocks.copyToClipboard).toHaveBeenCalledWith(
      'https://auth.openai.test/reauth',
      'admin.accounts.oauth.authUrlCopied'
    )
  })

  it('does not copy when OpenAI auth URL generation fails in reauthorization modal', async () => {
    primeOpenAIGenerate(false)

    const wrapper = mountReAuthAccountModal()

    await wrapper.find('.generate-url').trigger('click')
    await flushPromises()

    expect(mocks.openaiOAuth.generateAuthUrl).toHaveBeenCalledWith(9)
    expect(mocks.copyToClipboard).not.toHaveBeenCalled()
  })
})
