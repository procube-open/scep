import React from "react";
import {
  Admin,
  Resource,
  Layout,
  combineDataProviders,
  LayoutProps
} from "react-admin";
import { Route } from 'react-router-dom';
import ClientList from "./client/ListPage";
import ClientInfo from "./client/InfoPage";
import FilesList from "./files/ListPage";
import Sidebar from "./layouts/Sidebar";
import {
  baseDataProvider,
  ClientProvider,
  CertProvider,
  FilesProvider
} from "./dataProvider";
import i18nProvider from "./i18nProvider";

const layout = (props: LayoutProps) => (<Layout {...props}
  menu={Sidebar}
/>
);
const dataProviders = combineDataProviders((resource: string) => {
  if (resource === "client") return ClientProvider;
  if (resource === "cert") return CertProvider;
  if (resource === "files") return FilesProvider
  return baseDataProvider
});
export const App = () => {
  const [isAdmin, setIsAdmin] = React.useState(false);
  React.useEffect(() => {
    fetch("/sql/checkAdmin")
      .then((res) => {
        if (res.ok) setIsAdmin(true);
      })
  }, []);
  return (
    <Admin dataProvider={dataProviders} i18nProvider={i18nProvider} layout={layout}>
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
