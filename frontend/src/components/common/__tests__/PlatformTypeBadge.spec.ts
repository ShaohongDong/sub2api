import { describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import PlatformTypeBadge from '../PlatformTypeBadge.vue'

describe('PlatformTypeBadge', () => {
  it('renders normalized OpenAI plan labels', () => {
    const wrapper = mount(PlatformTypeBadge, {
      props: {
        platform: 'openai',
        type: 'oauth',
        planType: 'chatgptpro'
      },
      global: {
        stubs: {
          PlatformIcon: true,
          Icon: true
        }
      }
    })

    expect(wrapper.text()).toContain('OpenAI')
    expect(wrapper.text()).toContain('OAuth')
    expect(wrapper.text()).toContain('Pro')
  })

  it('preserves unknown plan types verbatim', () => {
    const wrapper = mount(PlatformTypeBadge, {
      props: {
        platform: 'openai',
        type: 'oauth',
        planType: 'enterprise-plus'
      },
      global: {
        stubs: {
          PlatformIcon: true,
          Icon: true
        }
      }
    })

    expect(wrapper.text()).toContain('enterprise-plus')
  })

  it('omits the plan segment when planType is empty', () => {
    const wrapper = mount(PlatformTypeBadge, {
      props: {
        platform: 'openai',
        type: 'oauth'
      },
      global: {
        stubs: {
          PlatformIcon: true,
          Icon: true
        }
      }
    })

    expect(wrapper.text()).toContain('OpenAI')
    expect(wrapper.text()).toContain('OAuth')
    expect(wrapper.text()).not.toContain('Plus')
    expect(wrapper.text()).not.toContain('Pro')
  })
})
