// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightScrollToTop from 'starlight-scroll-to-top';
import starlightUtils from "@lorenzo_lewis/starlight-utils";
import starlightLinksValidator from 'starlight-links-validator'
import starlightSidebarTopics from 'starlight-sidebar-topics';
import starlightKbd from 'starlight-kbd';
import autoImport from 'astro-auto-import';
import starlightGitHubAlerts from 'starlight-github-alerts';
import starlightThemeGalaxy from 'starlight-theme-galaxy';

// https://astro.build/config
export default defineConfig({
	site: 'https://wiki.egam.es',
	integrations: [
		autoImport({
			imports: [],
		}),
		starlight({
			components: {
				SiteTitle: './src/components/SiteTitle.astro',
			},
			plugins: [
				starlightThemeGalaxy(),
				starlightGitHubAlerts(),
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
			head: [
				// Plausible Analytics
				{
				tag: 'script',
				attrs: {
					async: true,
					src: 'https://ps.log.rw/js/pa-TLPk4Xvnye6Dh8hvwvH9n.js',
				},
				},
				{
				tag: 'script',
				content:
					'window.plausible=window.plausible||function(){(plausible.q=plausible.q||[]).push(arguments)},plausible.init=plausible.init||function(i){plausible.o=i||{}};plausible.init()',
				},
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
				{ icon: 'seti:zip', label: 'Used resources', href: '/contribution/resources' }
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
					label: 'Configuration Remnawave', translations: { ru: 'Настройка Remnawave' },
					items: [
						{ label: 'How to replace a domain', slug: 'configuration/how-to-replace-a-domain', translations: { ru: 'Как изменить домен' } },
						{ label: 'Access to Prometheus metrics', slug: 'configuration/prometheus-metrics', translations: { ru: 'Доступ к метрикам Prometheus' } },
						{ label: 'External access to API', slug: 'configuration/external-api', translations: { ru: 'Внешний доступ к API' } },
					],
				},
				{
					label: 'Configuration', translations: { ru: 'Настройка' },
					items: [
						{ label: 'Certwarden', slug: 'configuration/certwarden', translations: { ru: 'Certwarden' } },
						{ label: 'Warp Native', slug: 'configuration/warp-native', translations: { ru: 'Warp Native' } },
						{ label: 'Beszel', slug: 'configuration/beszel', translations: { ru: 'Beszel' } },
						{ label: 'Netbird', slug: 'configuration/netbird', translations: { ru: 'Netbird' } },
						{ label: 'Monitoring with Grafana and Victoria Metrics', slug: 'configuration/grafana-monitoring-setup', translations: { ru: 'Мониторинг через Grafana и Victoria Metrics' } },
						{ label: 'SWAG (Secure Web Application Gateway)', slug: 'configuration/swag', translations: { ru: 'SWAG (Secure Web Application Gateway)' } },
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
