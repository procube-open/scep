import React from "react";
import {
  Admin,
  Resource,
  Layout,
  defaultTheme,
  combineDataProviders,
  LayoutProps,
  RaThemeOptions
} from "react-admin";
import { colors } from '@mui/material';
import { Route } from 'react-router-dom';
import ClientList from "./client/ListPage/ListPage";
import ClientInfo from "./client/InfoPage/InfoPage";
import FilesList from "./files/ListPage";
import Sidebar from "./layouts/Sidebar";
import Appbar from "./layouts/Appbar";
import { IsAdminContext } from "./isAdminContext";
import {
  baseDataProvider,
  ClientProvider,
  CertProvider,
  FilesProvider,
  SecretProvider
} from "./dataProvider";
import i18nProvider from "./i18nProvider";

const layout = (props: LayoutProps) => (<Layout {...props}
  menu={Sidebar}
  appBar={Appbar}
/>
);
const dataProviders = combineDataProviders((resource: string) => {
  if (resource === "client") return ClientProvider;
  if (resource === "cert") return CertProvider;
  if (resource === "files") return FilesProvider;
  if (resource === "secret") return SecretProvider;
  return baseDataProvider
});

const adminTheme = {
  ...defaultTheme,
  palette: {
    ...defaultTheme.palette,
    primary: colors.lightGreen,
    secondary: {
      light: '#33ab9f',
      main: '#009688',
      dark: '#00695f',
      contrastText: '#fff',
    },
  }
};

const clientTheme = defaultTheme;

export const App = () => {
  const { setIsAdmin, adminMode, setAdminMode } = React.useContext(IsAdminContext);
  const [theme, setTheme] = React.useState<RaThemeOptions>(clientTheme);
  React.useEffect(() => {
    fetch("/sql/ping").then(async (res) => {
      const text = await res.text()
      if (text === "pong") {
        setIsAdmin(true)
        setTheme(adminTheme)
        setAdminMode(true)
      }
    })
  }, []);

  React.useEffect(() => {
    if (adminMode) {
      setTheme(adminTheme)
    }
    else {
      setTheme(clientTheme)
    }
  }, [adminMode]);

  return (
    <Admin
      dataProvider={dataProviders}
      i18nProvider={i18nProvider}
      layout={layout}
      theme={theme}
    >
      <Resource name="client">
        <Route path="/" element={<ClientList />} />
        <Route path="/:uid" element={<ClientInfo />} />
      </Resource>
      <Resource name="files">
        <Route path="*" element={<FilesList />} />
      </Resource>
      <Resource name="admin">
        <Route path="/" element={<ClientList />} />
      </Resource>
    </Admin>
  )
};
