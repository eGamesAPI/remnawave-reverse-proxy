// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightHeadingBadges from 'starlight-heading-badges';
import starlightScrollToTop from 'starlight-scroll-to-top';
import starlightUtils from "@lorenzo_lewis/starlight-utils";
import starlightLinksValidator from 'starlight-links-validator'
import starlightSidebarTopics from 'starlight-sidebar-topics';
import starlightKbd from 'starlight-kbd';
import starlightThemeRapide from 'starlight-theme-rapide';
import autoImport from 'astro-auto-import';

// https://astro.build/config
export default defineConfig({
	site: 'https://wiki.egam.es',
	integrations: [
		autoImport({
			imports: [
				'.src/components/TryItOut.astro',
				'.src/components/TryItOut_ru.astro',
			],
		}),
		starlight({
			components: {
				SiteTitle: './src/components/SiteTitle.astro',
			},
			plugins: [
				starlightThemeRapide(),
				starlightHeadingBadges(),
				starlightScrollToTop({
					showTooltip: false,
					borderRadius: '25',
				}),
				starlightKbd({
					globalPicker: false,
					types: [
						{ id: 'mac', label: 'macOS' },
						{ id: 'windows', label: 'Windows', default: true },
						{ id: 'linux', label: 'Linux' },
					]
				})
			],
			title: 'Remnawave Reverse-Proxy',
			logo: {
				src: './src/assets/logo.webp',
			},
			customCss: [
				'./src/styles/custom.css',
			],
			defaultLocale: 'root', // https://starlight.astro.build/guides/i18n/
			locales: {
				root: {
					label: 'English',
					lang: 'en', // lang is required for the root locales
				},
				'ru': {
					label: 'Русский',
					lang: 'ru',
				},
			},
			editLink: {
				baseUrl: "https://github.com/eGamesAPI/remnawave-reverse-proxy/edit/main/docs/",
			},
			social: [
				{ icon: 'github', label: 'GitHub', href: 'https://github.com/eGamesAPI/remnawave-reverse-proxy/' },
				{ icon: 'telegram', label: 'Telegram', href: 'https://t.me/remnawave_reverse' },
				{ icon: 'seti:zip', label: 'Used resources', href: '../../contribution/resources' }
			],
			sidebar: [
				{
					label: 'Introduction', translations: { ru: 'Введение' },
					items: [
						{ label: 'Overview', slug: 'introduction/overview', translations: { ru: 'Обзор' } },
					],
				},
				{
					label: 'Installation', translations: { ru: 'Установка' },
					items: [
						{ label: 'Requirements', slug: 'installation/requirements', translations: { ru: 'Обязательные условия' } },
						{ label: 'Panel and node', slug: 'installation/panel-and-node', translations: { ru: 'Панель и нода' } },
						{ label: 'Panel only', slug: 'installation/panel-only', translations: { ru: 'Только панель' } },
						{ label: 'Node only', slug: 'installation/node-only', translations: { ru: 'Только нода' } },
						{ label: 'Add node to panel', slug: 'installation/add-node', translations: { ru: 'Добавление ноды в панель' } },
					],
				},
				{
					label: 'Configuration', translations: { ru: 'Настройка' },
					items: [
						{ label: 'Access to Prometheus metrics', slug: 'configuration/prometheus-metrics', translations: { ru: 'Доступ к метрикам Prometheus' } },
						{ label: 'Beszel', slug: 'configuration/beszel', translations: { ru: 'Beszel' } },
						{ label: 'External access to API', slug: 'configuration/external-api', translations: { ru: 'Внешний доступ к API' } },
						{ label: 'Monitoring with Grafana', slug: 'configuration/monitoring-with-grafana', translations: { ru: 'Мониторинг через Grafana' } },
						{ label: 'Monitoring with Grafana and Victoria Metrics', slug: 'configuration/grafana-monitoring-setup', translations: { ru: 'Мониторинг через Grafana и Victoria Metrics' }, badge: {text: '🎉 New', variant: 'default'} },
						{ label: 'Netbird', slug: 'configuration/netbird', translations: { ru: 'Netbird' } },
						{ label: 'SWAG (Secure Web Application Gateway)', slug: 'configuration/swag', translations: { ru: 'SWAG (Secure Web Application Gateway)' }, badge: {text: '❌ WIP', variant: 'caution'} },
						{ label: 'Warp Native', slug: 'configuration/warp-native', translations: { ru: 'Warp Native' } },
					],
				},
				{
					label: 'Troubleshooting', translations: { ru: 'Устранение неполадок' },
					items: [
						{ label: 'Common issues', slug: 'troubleshooting/common-issues', translations: { ru: 'Частые проблемы' } },
						{ label: 'Docker related issues', slug: 'troubleshooting/docker-issues', translations: { ru: 'Проблемы, связанные с Docker' } },
						// { label: 'Logs', slug: 'troubleshooting/logs', translations: { ru: 'Логи' } },
					],
				},
				{
					label: 'Contribution', translations: { ru: 'Помощь в разработке' },
					items: [
						{ label: 'Contributors', slug: 'contribution/contributors', translations: { ru: 'Участники разработки' } },
						{ label: 'Contribution Guide', slug: 'contribution/guide', translations: { ru: 'Руководство по внесению изменений' } },
					],
				},
			],
		}),
	],
});



// TODO:
// add https://starlight-github-alerts.netlify.app/getting-started/
// https://www.create.bingo/
// https://octo.guide/